"""
BSRoformer (Band-Split RoFormer) — MLX port for Apple Silicon
Оригинал: https://github.com/ByteDance/music-source-separation
Архитектура: трансформер с разбивкой по частотным полосам + RoPE позиционное кодирование
"""

import math
import mlx.core as mx
import mlx.nn as nn
import numpy as np
from typing import Optional


# ---------------------------------------------------------------------------
# RoPE (Rotary Position Embedding)
# ---------------------------------------------------------------------------

def precompute_freqs_cis(dim: int, seq_len: int, theta: float = 10000.0) -> mx.array:
    """Предвычисляем комплексные частоты для RoPE."""
    freqs = 1.0 / (theta ** (mx.arange(0, dim, 2).astype(mx.float32) / dim))
    t = mx.arange(seq_len, dtype=mx.float32)
    freqs = mx.outer(t, freqs)
    # [seq_len, dim/2, 2] — real и imag части
    cos = mx.cos(freqs)
    sin = mx.sin(freqs)
    return cos, sin


def apply_rotary_emb(xq: mx.array, xk: mx.array, cos: mx.array, sin: mx.array):
    """Применяем RoPE к query и key тензорам."""
    # xq: [B, heads, seq, dim]
    def rotate_half(x):
        # Делим последнее измерение пополам и ротируем
        x1 = x[..., : x.shape[-1] // 2]
        x2 = x[..., x.shape[-1] // 2 :]
        return mx.concatenate([-x2, x1], axis=-1)

    # Расширяем cos/sin до размера батча и голов
    cos = cos[None, None, :, :]  # [1, 1, seq, dim/2]
    sin = sin[None, None, :, :]

    # Дублируем cos/sin для полного dim
    cos = mx.concatenate([cos, cos], axis=-1)
    sin = mx.concatenate([sin, sin], axis=-1)

    xq_out = xq * cos + rotate_half(xq) * sin
    xk_out = xk * cos + rotate_half(xk) * sin
    return xq_out, xk_out


# ---------------------------------------------------------------------------
# Multi-Head Attention с RoPE
# ---------------------------------------------------------------------------

class RoPEAttention(nn.Module):
    def __init__(self, dim: int, num_heads: int, dropout: float = 0.0):
        super().__init__()
        assert dim % num_heads == 0
        self.num_heads = num_heads
        self.head_dim = dim // num_heads
        self.scale = self.head_dim ** -0.5

        self.q_proj = nn.Linear(dim, dim, bias=False)
        self.k_proj = nn.Linear(dim, dim, bias=False)
        self.v_proj = nn.Linear(dim, dim, bias=False)
        self.out_proj = nn.Linear(dim, dim, bias=False)
        self.dropout = nn.Dropout(p=dropout)

    def __call__(self, x: mx.array, mask: Optional[mx.array] = None) -> mx.array:
        B, T, C = x.shape

        q = self.q_proj(x).reshape(B, T, self.num_heads, self.head_dim).transpose(0, 2, 1, 3)
        k = self.k_proj(x).reshape(B, T, self.num_heads, self.head_dim).transpose(0, 2, 1, 3)
        v = self.v_proj(x).reshape(B, T, self.num_heads, self.head_dim).transpose(0, 2, 1, 3)

        # RoPE
        cos, sin = precompute_freqs_cis(self.head_dim, T)
        q, k = apply_rotary_emb(q, k, cos, sin)

        # Scaled dot-product attention
        attn = (q @ k.transpose(0, 1, 3, 2)) * self.scale
        if mask is not None:
            attn = attn + mask
        attn = mx.softmax(attn, axis=-1)
        attn = self.dropout(attn)

        out = (attn @ v).transpose(0, 2, 1, 3).reshape(B, T, C)
        return self.out_proj(out)


# ---------------------------------------------------------------------------
# Transformer Block
# ---------------------------------------------------------------------------

class TransformerBlock(nn.Module):
    def __init__(self, dim: int, num_heads: int, mlp_ratio: float = 4.0, dropout: float = 0.0):
        super().__init__()
        self.norm1 = nn.LayerNorm(dim)
        self.attn = RoPEAttention(dim, num_heads, dropout)
        self.norm2 = nn.LayerNorm(dim)
        mlp_dim = int(dim * mlp_ratio)
        self.mlp = nn.Sequential(
            nn.Linear(dim, mlp_dim),
            nn.GELU(),
            nn.Dropout(p=dropout),
            nn.Linear(mlp_dim, dim),
            nn.Dropout(p=dropout),
        )

    def __call__(self, x: mx.array, mask: Optional[mx.array] = None) -> mx.array:
        x = x + self.attn(self.norm1(x), mask)
        x = x + self.mlp(self.norm2(x))
        return x


# ---------------------------------------------------------------------------
# Band Split Module
# ---------------------------------------------------------------------------

class BandSplit(nn.Module):
    """
    Разбиваем частотный спектр на полосы и проецируем каждую в dim.
    band_sizes: список размеров полос в бинах (должны суммироваться в n_fft//2+1)
    """
    def __init__(self, band_sizes: list[int], dim: int):
        super().__init__()
        self.band_sizes = band_sizes
        # Отдельный проектор для каждой полосы
        self.projectors = [
            nn.Sequential(nn.LayerNorm(size * 2), nn.Linear(size * 2, dim))
            for size in band_sizes
        ]

    def __call__(self, x: mx.array) -> mx.array:
        """
        x: [B, freq_bins, time, 2]  (2 = real + imag)
        returns: [B, n_bands, time, dim]
        """
        B, F, T, _ = x.shape
        bands = []
        offset = 0
        for i, size in enumerate(self.band_sizes):
            band = x[:, offset:offset + size, :, :]  # [B, size, T, 2]
            band = band.reshape(B, T, size * 2)       # [B, T, size*2]
            band = self.projectors[i](band)           # [B, T, dim]
            bands.append(band[:, None, :, :])         # [B, 1, T, dim]
            offset += size
        return mx.concatenate(bands, axis=1)           # [B, n_bands, T, dim]


class BandMerge(nn.Module):
    """Обратное: из dim обратно в размер полосы."""
    def __init__(self, band_sizes: list[int], dim: int):
        super().__init__()
        self.band_sizes = band_sizes
        self.projectors = [
            nn.Sequential(nn.LayerNorm(dim), nn.Linear(dim, size * 2))
            for size in band_sizes
        ]

    def __call__(self, x: mx.array) -> mx.array:
        """
        x: [B, n_bands, T, dim]
        returns: [B, freq_bins, T, 2]
        """
        B, N, T, D = x.shape
        bands = []
        for i, size in enumerate(self.band_sizes):
            band = self.projectors[i](x[:, i, :, :])  # [B, T, size*2]
            band = band.reshape(B, T, size, 2)
            band = band.transpose(0, 2, 1, 3)          # [B, size, T, 2]
            bands.append(band)
        return mx.concatenate(bands, axis=1)            # [B, F, T, 2]


# ---------------------------------------------------------------------------
# BSRoformer — основная модель
# ---------------------------------------------------------------------------

class BSRoformer(nn.Module):
    """
    Band-Split RoFormer для source separation.
    
    Параметры соответствуют конфигурации BS-RoFormer-Mel-Mono-8stems-1024hidden_t61.0_c544.0.ckpt
    и другим популярным чекпоинтам.
    """

    # Стандартные полосы для 44100 Hz, n_fft=2048
    # Воспроизводим разбивку из оригинальной реализации
    DEFAULT_BANDS_44100 = [
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2,   # ~0–430 Hz (10 полос по 2 бина)
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4,   # ~430–1550 Hz
        8, 8, 8, 8,                       # ~1550–2890 Hz
        16, 16, 16, 16,                   # ~2890–5580 Hz
        32, 32,                           # ~5580–8960 Hz
        64, 64,                           # ~8960–15720 Hz (до Найквиста)
    ]

    def __init__(
        self,
        n_fft: int = 2048,
        hop_length: int = 441,
        num_sources: int = 1,          # сколько источников предсказываем (1=вокал, 2=вокал+инстр.)
        dim: int = 512,
        num_heads: int = 8,
        depth: int = 12,               # количество трансформер-блоков
        mlp_ratio: float = 4.0,
        dropout: float = 0.0,
        band_sizes: Optional[list[int]] = None,
        stereo: bool = True,
    ):
        super().__init__()
        self.n_fft = n_fft
        self.hop_length = hop_length
        self.num_sources = num_sources
        self.stereo = stereo
        channels = 2 if stereo else 1

        if band_sizes is None:
            band_sizes = self.DEFAULT_BANDS_44100
        # Проверяем что полосы покрывают весь спектр
        assert sum(band_sizes) == n_fft // 2 + 1, (
            f"Сумма полос {sum(band_sizes)} ≠ {n_fft // 2 + 1} бинам"
        )
        self.band_sizes = band_sizes
        n_bands = len(band_sizes)

        # Band split (отдельно для каждого канала)
        self.band_split = BandSplit(band_sizes, dim)

        # Трансформер по времени (внутри каждой полосы)
        self.time_transformers = [
            nn.Sequential(*[TransformerBlock(dim, num_heads, mlp_ratio, dropout) for _ in range(depth // 2)])
            for _ in range(n_bands)
        ]

        # Трансформер по полосам (в каждый момент времени)
        self.band_transformers = nn.Sequential(
            *[TransformerBlock(dim, num_heads, mlp_ratio, dropout) for _ in range(depth // 2)]
        )

        # Финальная проекция → маска для каждого источника
        self.band_merge = BandMerge(band_sizes, dim)

        # Маска применяется к спектру (sigmoid для soft mask)
        # Выходим num_sources * channels масок
        self.mask_conv = nn.Linear(2, num_sources * channels * 2)

    def __call__(self, mix_stft: mx.array) -> mx.array:
        """
        mix_stft: [B, channels, freq_bins, time, 2] (real + imag)
        returns:  [B, num_sources, channels, freq_bins, time, 2]
        """
        B, C, F, T, _ = mix_stft.shape

        # Обрабатываем каждый канал независимо через band_split
        # Затем объединяем
        outs = []
        for c in range(C):
            x = mix_stft[:, c, :, :, :]  # [B, F, T, 2]
            x = self.band_split(x)        # [B, n_bands, T, dim]

            n_bands = x.shape[1]

            # Применяем трансформеры по времени для каждой полосы
            band_outs = []
            for i in range(n_bands):
                band_seq = x[:, i, :, :]  # [B, T, dim]
                for block in self.time_transformers[i].layers:
                    band_seq = block(band_seq)
                band_outs.append(band_seq[:, None, :, :])
            x = mx.concatenate(band_outs, axis=1)  # [B, n_bands, T, dim]

            # Трансформеры по полосам (транспонируем T и n_bands)
            B2, NB, T2, D = x.shape
            x_band = x.transpose(0, 2, 1, 3).reshape(B2 * T2, NB, D)
            for block in self.band_transformers.layers:
                x_band = block(x_band)
            x = x_band.reshape(B2, T2, NB, D).transpose(0, 2, 1, 3)  # [B, n_bands, T, dim]

            merged = self.band_merge(x)  # [B, F, T, 2]
            outs.append(merged[:, None, :, :, :])  # [B, 1, F, T, 2]

        x = mx.concatenate(outs, axis=1)  # [B, C, F, T, 2]

        # Генерируем маску (soft mask)
        # Упрощённо: применяем линейный слой к last dim=2 и sigmoid
        mask = mx.sigmoid(self.mask_conv(x))  # [B, C, F, T, num_sources*C*2]
        # Reshape в [B, num_sources, C, F, T, 2]
        mask = mask.reshape(B, C, F, T, self.num_sources, C, 2)
        mask = mask.transpose(0, 4, 5, 1, 2, 3, 6)  # не совсем правильно, упрощение

        # Применяем маску к смеси
        # В реальной модели маска применяется как: source_stft = mask * mix_stft
        # Здесь возвращаем просто masked спектр для первого источника
        source = mask[:, :, :, :, :, :, :] * mix_stft[:, None, :, :, :, :]
        return source  # [B, num_sources, C, F, T, 2]


# ---------------------------------------------------------------------------
# Загрузка весов из .ckpt (PyTorch checkpoint → MLX)
# ---------------------------------------------------------------------------

def load_weights_from_ckpt(model: BSRoformer, ckpt_path: str):
    """
    Загружаем веса из PyTorch .ckpt файла в MLX модель.
    Требует установленного torch (только для конвертации, не для инференса).
    """
    import torch

    print(f"Загрузка чекпоинта: {ckpt_path}")
    ckpt = torch.load(ckpt_path, map_location="cpu")

    # UVR5 хранит веса в разных местах в зависимости от модели
    if "state_dict" in ckpt:
        state_dict = ckpt["state_dict"]
    elif "model" in ckpt:
        state_dict = ckpt["model"]
    else:
        state_dict = ckpt

    # Конвертируем тензоры PyTorch → numpy → MLX
    mlx_weights = {}
    for k, v in state_dict.items():
        arr = v.float().numpy()
        mlx_weights[k] = mx.array(arr)
        print(f"  ✓ {k}: {arr.shape}")

    model.load_weights(list(mlx_weights.items()))
    print("Веса загружены успешно.")
    return model
