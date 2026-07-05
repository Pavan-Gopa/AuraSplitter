#!/usr/bin/env python3
"""
Конвертер весов: PyTorch .ckpt → MLX .safetensors
После конвертации torch больше не нужен для инференса.

Использование:
    python convert_weights.py --input model.ckpt --output model_mlx.safetensors
    python convert_weights.py --input models/ --output models_mlx/  (пакетная конвертация)
"""

import argparse
import sys
import json
import numpy as np
from pathlib import Path


def convert_ckpt_to_mlx(input_path: str, output_path: str, verbose: bool = True):
    """
    Конвертируем .ckpt файл в формат понятный MLX (numpy npz или safetensors).
    """
    try:
        import torch
    except ImportError:
        print("❌ torch не установлен. Нужен только для конвертации.")
        print("   pip install torch --index-url https://download.pytorch.org/whl/cpu")
        sys.exit(1)

    input_path = Path(input_path)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Читаем: {input_path}")
    ckpt = torch.load(input_path, map_location="cpu", weights_only=True)

    # Ищем state_dict
    if isinstance(ckpt, dict):
        if "state_dict" in ckpt:
            state_dict = ckpt["state_dict"]
        elif "model" in ckpt:
            state_dict = ckpt["model"]
        elif "model_state_dict" in ckpt:
            state_dict = ckpt["model_state_dict"]
        else:
            # Предполагаем что это и есть state_dict
            state_dict = ckpt
    else:
        raise ValueError(f"Неожиданный формат чекпоинта: {type(ckpt)}")

    print(f"Найдено {len(state_dict)} тензоров")

    # Конвертируем в numpy
    numpy_weights = {}
    total_params = 0
    for key, tensor in state_dict.items():
        # Нормализуем имена ключей (убираем префиксы типа 'module.' или 'model.')
        clean_key = key
        for prefix in ["module.", "model.", "_orig_mod."]:
            if clean_key.startswith(prefix):
                clean_key = clean_key[len(prefix):]

        arr = tensor.float().numpy()
        numpy_weights[clean_key] = arr
        total_params += arr.size

        if verbose:
            print(f"  {clean_key}: {arr.shape} ({arr.dtype})")

    print(f"\nВсего параметров: {total_params:,} ({total_params * 4 / 1024**2:.1f} MB)")

    # Сохраняем
    if output_path.suffix == ".npz":
        np.savez(output_path, **numpy_weights)
    elif output_path.suffix == ".safetensors":
        try:
            from safetensors.numpy import save_file
            save_file(numpy_weights, str(output_path))
        except ImportError:
            print("safetensors не установлен, сохраняем как .npz")
            output_path = output_path.with_suffix(".npz")
            np.savez(output_path, **numpy_weights)
    else:
        # По умолчанию npz
        if output_path.suffix != ".npz":
            output_path = output_path.with_suffix(".npz")
        np.savez(output_path, **numpy_weights)

    print(f"\n✓ Сохранено: {output_path}")
    print(f"  Размер файла: {output_path.stat().st_size / 1024**2:.1f} MB")

    # Сохраняем метаданные модели (конфигурацию)
    meta_path = output_path.with_suffix(".json")
    metadata = {
        "original_file": str(input_path.name),
        "num_tensors": len(numpy_weights),
        "total_params": total_params,
        "keys": list(numpy_weights.keys()),
    }

    # Пытаемся определить конфигурацию модели по именам ключей
    metadata["model_config"] = detect_model_config(numpy_weights)

    with open(meta_path, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"  Метаданные: {meta_path}")

    return str(output_path)


def detect_model_config(weights: dict) -> dict:
    """Пытаемся определить конфигурацию BSRoformer по именам весов."""
    config = {}

    # Определяем dim по размеру первого attention слоя
    for key, arr in weights.items():
        if "q_proj.weight" in key and len(arr.shape) == 2:
            config["dim"] = arr.shape[0]
            config["num_heads"] = arr.shape[0] // 64  # стандартный head_dim=64
            break

    # Считаем depth (количество трансформер блоков)
    depth = 0
    for key in weights.keys():
        if "time_transformers" in key and "norm1.weight" in key:
            # Находим максимальный индекс блока
            parts = key.split(".")
            for i, p in enumerate(parts):
                if p.isdigit():
                    depth = max(depth, int(p) + 1)

    if depth:
        config["depth"] = depth

    # Количество источников
    for key, arr in weights.items():
        if "mask_conv.weight" in key:
            config["num_sources_hint"] = arr.shape[0]

    return config


def batch_convert(input_dir: str, output_dir: str):
    """Конвертируем все .ckpt файлы в директории."""
    input_dir = Path(input_dir)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    ckpt_files = list(input_dir.glob("*.ckpt")) + list(input_dir.glob("*.pth"))

    if not ckpt_files:
        print(f"Нет .ckpt файлов в {input_dir}")
        return

    print(f"Найдено {len(ckpt_files)} файлов для конвертации\n")

    for ckpt_path in ckpt_files:
        out_path = output_dir / (ckpt_path.stem + ".npz")
        print(f"\n{'='*60}")
        try:
            convert_ckpt_to_mlx(str(ckpt_path), str(out_path))
        except Exception as e:
            print(f"❌ Ошибка при конвертации {ckpt_path.name}: {e}")


def verify_conversion(original_ckpt: str, converted_npz: str):
    """Проверяем что конвертация прошла корректно."""
    import torch
    import mlx.core as mx

    print("Верификация конвертации...")

    # Загружаем оригинал
    ckpt = torch.load(original_ckpt, map_location="cpu")
    if "state_dict" in ckpt:
        orig = ckpt["state_dict"]
    else:
        orig = ckpt

    # Загружаем конвертированный
    converted = np.load(converted_npz)

    errors = []
    for key in orig:
        clean_key = key
        for prefix in ["module.", "model.", "_orig_mod."]:
            if clean_key.startswith(prefix):
                clean_key = clean_key[len(prefix):]

        if clean_key not in converted:
            errors.append(f"Ключ '{clean_key}' отсутствует в конвертированном файле")
            continue

        orig_arr = orig[key].float().numpy()
        conv_arr = converted[clean_key]

        max_diff = np.abs(orig_arr - conv_arr).max()
        if max_diff > 1e-6:
            errors.append(f"'{clean_key}': max diff = {max_diff:.2e}")

    if errors:
        print(f"❌ Найдено {len(errors)} ошибок:")
        for e in errors:
            print(f"  - {e}")
    else:
        print(f"✓ Все {len(orig)} тензоров совпадают")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Конвертер весов BSRoformer → MLX")
    parser.add_argument("--input", required=True, help="Путь к .ckpt файлу или директории")
    parser.add_argument("--output", required=True, help="Путь для выходного файла или директории")
    parser.add_argument("--verify", action="store_true", help="Верифицировать конвертацию")
    parser.add_argument("--quiet", action="store_true", help="Минимальный вывод")
    args = parser.parse_args()

    input_path = Path(args.input)

    if input_path.is_dir():
        batch_convert(args.input, args.output)
    else:
        out = convert_ckpt_to_mlx(args.input, args.output, verbose=not args.quiet)
        if args.verify:
            verify_conversion(args.input, out)
