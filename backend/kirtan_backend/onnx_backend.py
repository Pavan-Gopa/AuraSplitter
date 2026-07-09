from __future__ import annotations

import logging
import subprocess
import tempfile
import time
from collections.abc import Callable
from pathlib import Path


PolarFormerProgressCallback = Callable[[str, str, float], None]
CancelCallback = Callable[[], None]


def onnx_runtime_status() -> dict:
    try:
        import onnxruntime as ort
    except Exception as exc:
        return {
            "available": False,
            "status": f"unavailable: {type(exc).__name__}: {exc}",
            "providers": [],
            "preferredProvider": None,
        }

    providers = list(ort.get_available_providers())
    preferred = _preferred_provider(providers)
    return {
        "available": True,
        "status": "ok",
        "version": getattr(ort, "__version__", "unknown"),
        "providers": providers,
        "preferredProvider": preferred,
    }


def _preferred_provider(providers: list[str]) -> str | None:
    for candidate in (
        "CoreMLExecutionProvider",
        "CUDAExecutionProvider",
        "DmlExecutionProvider",
        "CPUExecutionProvider",
    ):
        if candidate in providers:
            return candidate
    return providers[0] if providers else None


class DemucsOnnxBackend:
    def __init__(self, model_dir: str, logger: logging.Logger | None = None):
        self.model_dir = Path(model_dir).expanduser()
        self.cache_dir = self.model_dir / "onnx"
        self.logger = logger or logging.getLogger("kirtan_backend.onnx_backend")
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def separate(
        self,
        input_path: str,
        output_dir: str,
        output_format: str,
        model: str,
        stems: tuple[str, ...] | None = None,
    ) -> list[str]:
        try:
            import demucs_onnx
        except Exception as exc:
            raise RuntimeError(
                "ONNX/CoreML backend is not installed. Run script/setup_backend.sh "
                "to install demucs-onnx and onnxruntime."
            ) from exc

        output_path = Path(output_dir).expanduser()
        output_path.mkdir(parents=True, exist_ok=True)
        requested_format = output_format.lower()
        demucs_format = "mp3" if requested_format == "mp3" else "wav"

        self.logger.info(
            "Running demucs-onnx model=%s input=%s output_dir=%s cache_dir=%s format=%s",
            model,
            input_path,
            output_path,
            self.cache_dir,
            demucs_format,
        )
        result = demucs_onnx.separate(
            input_path,
            output_dir=str(output_path),
            model=model,
            stems=stems,
            providers="auto",
            cache_dir=str(self.cache_dir),
            verbose=False,
            progress=False,
            output_format=demucs_format,
        )

        files = [
            output_path / f"{stem}.{demucs_format}"
            for stem in sorted(result.keys())
        ]
        missing = [str(path) for path in files if not path.exists()]
        if missing:
            raise RuntimeError("ONNX backend did not write expected stem files: " + ", ".join(missing))

        if requested_format == "flac":
            return self._convert_wav_outputs_to_flac(files)
        return [str(path) for path in files]

    def _convert_wav_outputs_to_flac(self, wav_files: list[Path]) -> list[str]:
        flac_files = []
        for wav_path in wav_files:
            flac_path = wav_path.with_suffix(".flac")
            command = [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(wav_path),
                "-c:a",
                "flac",
                str(flac_path),
            ]
            try:
                subprocess.run(command, check=True, capture_output=True, text=True, timeout=None)
                wav_path.unlink(missing_ok=True)
                flac_files.append(str(flac_path))
            except subprocess.CalledProcessError as exc:
                message = (exc.stderr or exc.stdout or str(exc)).strip()
                raise RuntimeError(f"Failed to convert ONNX output to FLAC: {message}") from exc
        return flac_files


class PolarFormerOnnxBackend:
    def __init__(self, model_dir: str, logger: logging.Logger | None = None):
        self.model_dir = Path(model_dir).expanduser()
        self.cache_dir = self.model_dir / "onnx"
        self.coreml_cache_dir = self.cache_dir / "coreml-cache"
        self.logger = logger or logging.getLogger("kirtan_backend.onnx_backend")
        self.model_dir.mkdir(parents=True, exist_ok=True)
        self.coreml_cache_dir.mkdir(parents=True, exist_ok=True)
        self.last_perf_metrics: dict[str, float] = {}

    def separate(
        self,
        input_path: str,
        output_dir: str,
        output_format: str,
        model: str,
        config_filename: str,
        progress_callback: PolarFormerProgressCallback | None = None,
        progress_start: float = 0.08,
        progress_end: float = 0.92,
        cancel_callback: CancelCallback | None = None,
    ) -> list[str]:
        model_path = self.model_dir / model
        config_path = self.model_dir / config_filename
        if not model_path.is_file():
            raise FileNotFoundError(f"PolarFormer ONNX model is missing: {model_path}")
        if not config_path.is_file():
            raise FileNotFoundError(f"PolarFormer config is missing: {config_path}")

        output_path = Path(output_dir).expanduser()
        output_path.mkdir(parents=True, exist_ok=True)
        requested_format = output_format.lower()
        config = self._load_config(config_path)
        sample_rate = int(config.get("audio", {}).get("sample_rate", 44100))

        started = time.perf_counter()
        with tempfile.TemporaryDirectory(prefix="kirtan-polarformer-") as temp_dir:
            prepared_input = Path(temp_dir) / "input.wav"
            self._decode_to_model_input(input_path, prepared_input, sample_rate)
            _check_cancelled(cancel_callback)
            audio, load_seconds = self._read_stereo_audio(prepared_input)
            _check_cancelled(cancel_callback)

            inference_started = time.perf_counter()
            vocals = self._run_chunked_inference(
                audio=audio,
                config=config,
                model_path=model_path,
                progress_callback=progress_callback,
                progress_start=progress_start,
                progress_end=progress_end,
                cancel_callback=cancel_callback,
            )
            inference_seconds = time.perf_counter() - inference_started

        _check_cancelled(cancel_callback)
        write_started = time.perf_counter()
        vocals_path = output_path / "vocals.wav"
        instrumental_path = output_path / "instrumental.wav"
        self._write_float_wav(vocals_path, vocals, sample_rate)
        instrumental = audio[:, : vocals.shape[1]] - vocals
        self._write_float_wav(instrumental_path, instrumental, sample_rate)
        files = [vocals_path, instrumental_path]
        write_seconds = time.perf_counter() - write_started

        self.last_perf_metrics = {
            "decode_s": round(load_seconds, 4),
            "inference_s": round(inference_seconds, 4),
            "write_s": round(write_seconds, 4),
            "total_s": round(time.perf_counter() - started, 4),
        }

        if requested_format in {"flac", "mp3"}:
            files = self._convert_wav_outputs(files, requested_format)
        return [str(path) for path in files]

    def _load_config(self, config_path: Path) -> dict:
        try:
            import yaml
        except Exception as exc:
            raise RuntimeError("PyYAML is required for the PolarFormer ONNX backend.") from exc
        with open(config_path, "r", encoding="utf-8") as handle:
            return yaml.full_load(handle) or {}

    def _decode_to_model_input(self, input_path: str, output_path: Path, sample_rate: int):
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(input_path),
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "2",
            "-ar",
            str(sample_rate),
            "-c:a",
            "pcm_f32le",
            str(output_path),
        ]
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=None)
        except subprocess.CalledProcessError as exc:
            message = (exc.stderr or exc.stdout or str(exc)).strip()
            raise RuntimeError(f"Failed to prepare PolarFormer input with ffmpeg: {message}") from exc

    def _read_stereo_audio(self, path: Path):
        try:
            import soundfile as sf
        except Exception as exc:
            raise RuntimeError("soundfile is required for the PolarFormer ONNX backend.") from exc

        started = time.perf_counter()
        audio, _sample_rate = sf.read(str(path), dtype="float32", always_2d=True)
        if audio.shape[1] < 2:
            audio = _duplicate_mono_channel(audio)
        if audio.shape[1] > 2:
            audio = audio[:, :2]
        return audio.T.copy(), time.perf_counter() - started

    def _run_chunked_inference(
        self,
        audio,
        config: dict,
        model_path: Path,
        progress_callback: PolarFormerProgressCallback | None = None,
        progress_start: float = 0.08,
        progress_end: float = 0.92,
        cancel_callback: CancelCallback | None = None,
    ):
        import numpy as np

        inference = config.get("inference", {})
        chunk_size = max(1, int(inference.get("chunk_size", 882000)))
        num_overlap = max(1, int(inference.get("num_overlap", 2)))
        step = max(1, chunk_size // num_overlap)
        total_samples = int(audio.shape[1])
        if total_samples <= 0:
            raise RuntimeError("PolarFormer input has no audio samples.")

        if progress_callback is not None:
            progress_callback("loading", "Compiling PolarFormer CoreML session", min(progress_start, 0.07))
        session = self._create_session(model_path)
        if progress_callback is not None:
            progress_callback("loading", "PolarFormer CoreML session ready", progress_start)
        result = np.zeros((2, total_samples), dtype=np.float32)
        count = np.zeros(total_samples, dtype=np.float32)
        total_chunks = max(1, (total_samples + step - 1) // step)
        processed_chunks = 0

        for start in range(0, total_samples, step):
            _check_cancelled(cancel_callback)
            end = min(start + chunk_size, total_samples)
            actual_len = end - start
            chunk = np.zeros((2, chunk_size), dtype=np.float32)
            chunk[:, :actual_len] = audio[:, start:end]

            features, stft_repr, stft_window, raw_audio_len = self._prepare_stft(chunk, config)
            _check_cancelled(cancel_callback)
            mask = session.run(None, {"stft_features": features})[0]
            _check_cancelled(cancel_callback)
            recon = self._reconstruct_audio(
                stft_repr=stft_repr,
                mask=mask,
                stft_window=stft_window,
                raw_audio_len=raw_audio_len,
                config=config,
            )
            result[:, start:end] += recon[:, :actual_len]
            count[start:end] += 1.0
            processed_chunks += 1
            _emit_polarformer_progress(
                progress_callback,
                "separating",
                f"PolarFormer chunk {processed_chunks}/{total_chunks}",
                progress_start,
                progress_end,
                processed_chunks,
                total_chunks,
            )

        count = np.maximum(count, 1.0)
        return result / count[np.newaxis, :]

    def _create_session(self, model_path: Path):
        try:
            import onnxruntime as ort
        except Exception as exc:
            raise RuntimeError(
                "ONNX Runtime is required for the PolarFormer backend. Run script/setup_backend.sh."
            ) from exc

        providers = _ordered_onnx_providers(
            list(ort.get_available_providers()),
            coreml_cache_dir=self.coreml_cache_dir,
        )
        if not providers:
            raise RuntimeError(
                "Kirtan Vocal Max cannot run because ONNX Runtime does not expose "
                "CoreMLExecutionProvider. CPU fallback is disabled for PolarFormer "
                "because this model takes hours without CoreML/Neural Engine."
            )
        self.logger.info("Creating PolarFormer ONNX Runtime session providers=%s", providers)
        try:
            return ort.InferenceSession(str(model_path), providers=providers)
        except Exception as exc:
            self.logger.exception("PolarFormer CoreML session failed; CPU fallback disabled.")
            raise RuntimeError(
                "Kirtan Vocal Max cannot run on CoreML/Neural Engine with the current "
                "BS PolarFormer ONNX checkpoint. CoreML reported unsupported dynamic "
                "or unbounded tensor shapes. CPU fallback is disabled because it would "
                "run for hours; use Kirtan Vocal Elite or another MLX preset until a "
                "static CoreML/MLX export is added."
            ) from exc

    def _prepare_stft(self, audio, config: dict):
        import torch

        model = config.get("model", {})
        stft_kwargs = self._stft_kwargs(model)
        with torch.inference_mode():
            raw_audio = torch.from_numpy(audio).float()
            stft_window = torch.hann_window(stft_kwargs["win_length"])
            stft_repr = torch.stft(raw_audio, **stft_kwargs, window=stft_window, return_complex=True)
            stft_repr = torch.view_as_real(stft_repr)
            freq_bins = stft_repr.shape[1]
            frames = stft_repr.shape[2]
            stft_repr = (
                stft_repr.permute(1, 0, 2, 3)
                .contiguous()
                .reshape(1, freq_bins * 2, frames, 2)
            )
            features = (
                stft_repr.permute(0, 2, 1, 3)
                .contiguous()
                .reshape(1, frames, freq_bins * 2 * 2)
                .numpy()
            )
        return features, stft_repr, stft_window, raw_audio.shape[-1]

    def _reconstruct_audio(self, stft_repr, mask, stft_window, raw_audio_len: int, config: dict):
        import torch

        model = config.get("model", {})
        stft_kwargs = self._stft_kwargs(model)
        audio_channels = 2 if model.get("stereo", True) else 1
        freq_bins = int(model.get("stft_n_fft", 2048)) // 2 + 1

        with torch.inference_mode():
            mask_tensor = torch.from_numpy(mask).float()
            stft_c = torch.view_as_complex(stft_repr.unsqueeze(1).contiguous())
            mask_c = torch.view_as_complex(mask_tensor.contiguous())
            masked = stft_c * mask_c
            batch, stems, _flat_bins, frames = masked.shape
            masked = (
                masked.reshape(batch, stems, freq_bins, audio_channels, frames)
                .permute(0, 1, 3, 2, 4)
                .contiguous()
                .reshape(batch * stems * audio_channels, freq_bins, frames)
            )
            masked[:, 0, :] = 0.0
            recon = torch.istft(
                masked,
                **stft_kwargs,
                window=stft_window,
                return_complex=False,
                length=raw_audio_len,
            )
            recon = recon.reshape(batch, stems, audio_channels, raw_audio_len)
            return recon[0, 0].numpy()

    def _stft_kwargs(self, model_config: dict) -> dict:
        return {
            "n_fft": int(model_config.get("stft_n_fft", 2048)),
            "hop_length": int(model_config.get("stft_hop_length", 512)),
            "win_length": int(model_config.get("stft_win_length", 2048)),
            "normalized": bool(model_config.get("stft_normalized", False)),
        }

    def _write_float_wav(self, path: Path, audio, sample_rate: int):
        try:
            import soundfile as sf
        except Exception as exc:
            raise RuntimeError("soundfile is required for the PolarFormer ONNX backend.") from exc
        sf.write(str(path), audio.T, sample_rate, subtype="FLOAT")

    def _convert_wav_outputs(self, wav_files: list[Path], output_format: str) -> list[Path]:
        converted_files = []
        codec = "flac" if output_format == "flac" else "libmp3lame"
        for wav_path in wav_files:
            target_path = wav_path.with_suffix(f".{output_format}")
            command = [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(wav_path),
                "-c:a",
                codec,
                str(target_path),
            ]
            try:
                subprocess.run(command, check=True, capture_output=True, text=True, timeout=None)
                wav_path.unlink(missing_ok=True)
                converted_files.append(target_path)
            except subprocess.CalledProcessError as exc:
                message = (exc.stderr or exc.stdout or str(exc)).strip()
                raise RuntimeError(f"Failed to convert PolarFormer output to {output_format.upper()}: {message}") from exc
        return converted_files


def _ordered_onnx_providers(providers: list[str], coreml_cache_dir: Path | None = None) -> list:
    if "CoreMLExecutionProvider" in providers:
        return [_provider_spec("CoreMLExecutionProvider", coreml_cache_dir)]
    return []


def _provider_spec(provider: str, coreml_cache_dir: Path | None):
    if provider != "CoreMLExecutionProvider":
        return provider
    options = {
        "ModelFormat": "MLProgram",
        "MLComputeUnits": "ALL",
        "RequireStaticInputShapes": "0",
        "EnableOnSubgraphs": "0",
    }
    if coreml_cache_dir is not None:
        options["ModelCacheDirectory"] = str(coreml_cache_dir)
    return provider, options


def _emit_polarformer_progress(
    progress_callback: PolarFormerProgressCallback | None,
    stage: str,
    message: str,
    start: float,
    end: float,
    processed_chunks: int,
    total_chunks: int,
):
    if progress_callback is None:
        return
    span = max(0.0, end - start)
    ratio = min(1.0, max(0.0, processed_chunks / max(1, total_chunks)))
    progress_callback(stage, message, round(start + span * ratio, 4))


def _check_cancelled(cancel_callback: CancelCallback | None):
    if cancel_callback is not None:
        cancel_callback()


def _duplicate_mono_channel(audio):
    import numpy as np

    return np.repeat(audio[:, :1], 2, axis=1)
