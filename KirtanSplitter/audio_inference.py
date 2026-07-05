"""
Audio inference: STFT → BSRoformer → iSTFT
Оптимизировано для Apple Silicon через MLX + scipy STFT.
"""

import numpy as np
import mlx.core as mx
import soundfile as sf
from scipy.signal import stft, istft
from pathlib import Path
from typing import Callable, Optional
import time


# ---------------------------------------------------------------------------
# STFT / iSTFT обёртки (scipy — быстро и надёжно)
# ---------------------------------------------------------------------------

def audio_to_stft(audio: np.ndarray, n_fft: int, hop_length: int) -> np.ndarray:
    """
    audio: [channels, samples]  float32 в диапазоне [-1, 1]
    returns: [channels, freq_bins, time_frames, 2]  (real + imag)
    """
    channels = audio.shape[0]
    results = []
    for c in range(channels):
        freqs, times, spec = stft(
            audio[c],
            nperseg=n_fft,
            noverlap=n_fft - hop_length,
            window='hann',
        )
        # spec: complex [freq_bins, time_frames]
        ri = np.stack([spec.real, spec.imag], axis=-1)  # [F, T, 2]
        results.append(ri)
    return np.stack(results, axis=0)  # [C, F, T, 2]


def stft_to_audio(spec: np.ndarray, n_fft: int, hop_length: int, length: int) -> np.ndarray:
    """
    spec: [channels, freq_bins, time_frames, 2]
    returns: [channels, samples]
    """
    channels = spec.shape[0]
    results = []
    for c in range(channels):
        complex_spec = spec[c, :, :, 0] + 1j * spec[c, :, :, 1]
        _, audio = istft(
            complex_spec,
            nperseg=n_fft,
            noverlap=n_fft - hop_length,
            window='hann',
        )
        audio = audio[:length]
        results.append(audio)
    return np.stack(results, axis=0)


# ---------------------------------------------------------------------------
# Чанковый инференс (обрабатываем длинные треки кусками)
# ---------------------------------------------------------------------------

def run_inference_chunked(
    model,
    audio: np.ndarray,
    n_fft: int = 2048,
    hop_length: int = 441,
    chunk_seconds: float = 30.0,
    overlap_seconds: float = 2.0,
    sample_rate: int = 44100,
    progress_cb: Optional[Callable[[float], None]] = None,
) -> np.ndarray:
    """
    Запускаем модель на длинном аудио чанками с overlap для устранения артефактов.
    
    audio: [channels, samples]
    returns: [num_sources, channels, samples]
    """
    channels, total_samples = audio.shape
    chunk_samples = int(chunk_seconds * sample_rate)
    overlap_samples = int(overlap_seconds * sample_rate)
    hop_samples = chunk_samples - overlap_samples

    # Паддинг для равномерных чанков
    pad_length = chunk_samples - (total_samples % hop_samples) if total_samples % hop_samples else 0
    audio_padded = np.pad(audio, ((0, 0), (0, pad_length)), mode='reflect')

    num_chunks = max(1, (audio_padded.shape[1] - chunk_samples) // hop_samples + 1)

    # Окно для overlap-add (Hanning)
    fade = np.linspace(0, 1, overlap_samples)
    window = np.concatenate([fade, np.ones(chunk_samples - 2 * overlap_samples), fade[::-1]])

    # Буфер результата (пока не знаем num_sources — возьмём из первого чанка)
    result_buffer = None
    weight_buffer = np.zeros(audio_padded.shape[1])

    for i in range(num_chunks):
        start = i * hop_samples
        end = start + chunk_samples
        chunk = audio_padded[:, start:end]  # [C, chunk_samples]

        # STFT
        chunk_stft = audio_to_stft(chunk, n_fft, hop_length)  # [C, F, T, 2]
        chunk_mx = mx.array(chunk_stft[None].astype(np.float32))  # [1, C, F, T, 2]

        # Инференс на MLX (GPU/ANE через Metal)
        t0 = time.time()
        with mx.no_grad():
            sources_mx = model(chunk_mx)  # [1, num_sources, C, F, T, 2]
        mx.eval(sources_mx)  # Синхронизируем вычисления
        elapsed = time.time() - t0

        sources_np = np.array(sources_mx[0])  # [num_sources, C, F, T, 2]
        num_sources = sources_np.shape[0]

        # Инициализируем буфер после первого чанка
        if result_buffer is None:
            result_buffer = np.zeros((num_sources, channels, audio_padded.shape[1]))

        # iSTFT для каждого источника
        for s in range(num_sources):
            source_audio = stft_to_audio(sources_np[s], n_fft, hop_length, chunk_samples)
            # Overlap-add с windowing
            for c in range(channels):
                result_buffer[s, c, start:end] += source_audio[c] * window

        weight_buffer[start:end] += window

        if progress_cb:
            progress_cb((i + 1) / num_chunks)

        print(f"  Чанк {i+1}/{num_chunks} — {elapsed:.2f}с")

    # Нормализуем по весам
    weight_buffer = np.maximum(weight_buffer, 1e-8)
    result_buffer /= weight_buffer[None, None, :]

    # Обрезаем паддинг и возвращаем
    return result_buffer[:, :, :total_samples]


# ---------------------------------------------------------------------------
# Главная функция разделения одного трека
# ---------------------------------------------------------------------------

def separate_track(
    model,
    input_path: str,
    output_dir: str,
    stem_names: list[str],
    n_fft: int = 2048,
    hop_length: int = 441,
    chunk_seconds: float = 30.0,
    progress_cb: Optional[Callable[[float], None]] = None,
) -> list[str]:
    """
    Разделяет аудиофайл на stems.
    Возвращает список путей к выходным файлам.
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Читаем: {input_path}")
    audio, sr = sf.read(input_path, dtype='float32', always_2d=True)
    audio = audio.T  # soundfile → [samples, channels], нам нужно [channels, samples]

    # Ресемплинг если нужно (модель обучена на 44100)
    if sr != 44100:
        import resampy
        print(f"Ресемплинг {sr} → 44100 Hz...")
        audio = resampy.resample(audio, sr, 44100, axis=1)
        sr = 44100

    print(f"Длительность: {audio.shape[1] / sr:.1f}с, каналов: {audio.shape[0]}")

    # Нормализуем
    max_val = np.abs(audio).max()
    if max_val > 0:
        audio = audio / max_val

    print("Запускаем инференс...")
    sources = run_inference_chunked(
        model, audio,
        n_fft=n_fft,
        hop_length=hop_length,
        chunk_seconds=chunk_seconds,
        sample_rate=sr,
        progress_cb=progress_cb,
    )
    # sources: [num_sources, channels, samples]

    # Денормализуем и сохраняем
    sources = sources * max_val
    input_stem = Path(input_path).stem
    output_paths = []

    for i, name in enumerate(stem_names):
        if i >= sources.shape[0]:
            break
        out_audio = sources[i].T  # [samples, channels]
        out_path = output_dir / f"{input_stem}_{name}.wav"
        sf.write(str(out_path), out_audio, sr, subtype='PCM_24')
        print(f"  Сохранён: {out_path}")
        output_paths.append(str(out_path))

    return output_paths
