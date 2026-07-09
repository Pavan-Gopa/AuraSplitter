from __future__ import annotations

import os
import platform
import re
import subprocess
import time
from pathlib import Path

from .model_catalog import metadata_for_model_stem, model_library_metadata_entries
from .onnx_backend import onnx_runtime_status
from .render_estimates import model_usage_counts


MODEL_SUFFIXES = {".ckpt", ".onnx", ".pth", ".yaml", ".safetensors"}
SOURCE_MODEL_SUFFIXES = {".ckpt", ".onnx", ".pth"}
SOURCE_PLACEHOLDER_PREFIX = "KirtanSplitter source checkpoint removed after MLX conversion."


def runtime_stats(model_dir: str) -> dict:
    return {
        "timestamp": time.time(),
        "cpu": cpu_stats(),
        "memory": memory_stats(),
        "process": process_stats(os.getpid()),
        "gpu": gpu_stats(),
        "coreML": coreml_stats(),
        "modelCache": model_cache_summary(model_dir),
    }


def cpu_stats() -> dict:
    core_count = os.cpu_count() or 1
    cpu_sum = 0.0
    try:
        output = subprocess.check_output(["ps", "-A", "-o", "%cpu="], text=True, timeout=2)
        cpu_sum = sum(float(line.strip() or 0) for line in output.splitlines())
    except Exception:
        cpu_sum = 0.0
    return {
        "systemPercent": round(min(100.0, cpu_sum / core_count), 1),
        "aggregatePercent": round(cpu_sum, 1),
        "coreCount": core_count,
        "loadAverage": [round(value, 2) for value in os.getloadavg()],
    }


def memory_stats() -> dict:
    total = 0
    if hasattr(os, "sysconf"):
        try:
            total = int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES"))
        except Exception:
            total = 0

    used = 0
    try:
        page_size = 4096
        vm_output = subprocess.check_output(["vm_stat"], text=True, timeout=2)
        stats = {}
        for line in vm_output.splitlines():
            match = re.match(r"^(.+?):\s+([0-9]+)\.", line.strip())
            if match:
                stats[match.group(1)] = int(match.group(2))
        active = stats.get("Pages active", 0)
        wired = stats.get("Pages wired down", 0)
        compressed = stats.get("Pages occupied by compressor", 0)
        speculative = stats.get("Pages speculative", 0)
        used = (active + wired + compressed + speculative) * page_size
    except Exception:
        used = 0

    used_percent = (used / total * 100.0) if total else 0.0
    return {
        "totalBytes": total,
        "usedBytes": used,
        "usedPercent": round(used_percent, 1),
    }


def process_stats(pid: int) -> dict:
    try:
        output = subprocess.check_output(["ps", "-p", str(pid), "-o", "pid=,%cpu=,rss="], text=True, timeout=2)
        parts = output.split()
        rss_kb = int(float(parts[2])) if len(parts) >= 3 else 0
        return {
            "pid": int(parts[0]) if parts else pid,
            "cpuPercent": round(float(parts[1]), 1) if len(parts) >= 2 else 0.0,
            "rssBytes": rss_kb * 1024,
        }
    except Exception:
        return {"pid": pid, "cpuPercent": 0.0, "rssBytes": 0}


def gpu_stats() -> dict:
    device = "unknown"
    try:
        import mlx.core as mx

        device = str(mx.default_device())
    except Exception:
        pass

    sample = try_powermetrics_gpu()
    if sample.get("utilizationPercent") is None and sample.get("powerWatts") is None:
        ioreg_sample = try_ioreg_gpu()
        if ioreg_sample.get("status") == "ok":
            sample = ioreg_sample

    return {
        "device": device,
        "utilizationPercent": sample.get("utilizationPercent"),
        "powerWatts": sample.get("powerWatts"),
        "gpuCoreCount": sample.get("gpuCoreCount"),
        "status": sample.get("status", "unavailable"),
        "source": sample.get("source", "powermetrics"),
    }


def coreml_stats() -> dict:
    status = onnx_runtime_status()
    providers = status.get("providers") or []
    coreml_available = "CoreMLExecutionProvider" in providers
    provider = "CoreMLExecutionProvider" if coreml_available else status.get("preferredProvider")

    return {
        "provider": provider,
        "computeUnits": "ALL" if coreml_available else "unavailable",
        "gpuAllowed": coreml_available,
        "neuralEngineAllowed": coreml_available,
        "status": "ok" if coreml_available else status.get("status", "unavailable"),
        "source": "onnxruntime-coreml",
    }


def try_powermetrics_gpu() -> dict:
    try:
        output = subprocess.check_output(
            ["/usr/bin/powermetrics", "--samplers", "gpu_power", "-n", "1", "-i", "250"],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=2,
        )
    except Exception as exc:
        return {"status": f"unavailable: {type(exc).__name__}"}

    utilization = None
    power_watts = None
    util_match = re.search(r"GPU Active residency:\s+([0-9.]+)%", output)
    if util_match:
        utilization = float(util_match.group(1))

    power_match = re.search(r"GPU Power:\s+([0-9.]+)\s+mW", output)
    if power_match:
        power_watts = round(float(power_match.group(1)) / 1000.0, 2)

    return {
        "utilizationPercent": utilization,
        "powerWatts": power_watts,
        "status": "ok" if utilization is not None or power_watts is not None else "unavailable",
    }


def try_ioreg_gpu() -> dict:
    try:
        output = subprocess.check_output(
            ["ioreg", "-r", "-c", "IOAccelerator", "-w0"],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=2,
        )
    except Exception as exc:
        return {"status": f"unavailable: {type(exc).__name__}", "source": "ioreg"}
    return parse_ioreg_gpu_stats(output)


def parse_ioreg_gpu_stats(output: str) -> dict:
    utilization = _ioreg_number(output, "Device Utilization %")
    renderer = _ioreg_number(output, "Renderer Utilization %")
    tiler = _ioreg_number(output, "Tiler Utilization %")
    in_use_memory = _ioreg_number(output, "In use system memory")
    allocated_memory = _ioreg_number(output, "Alloc system memory")
    gpu_core_count = _ioreg_number(output, "gpu-core-count")

    result = {
        "utilizationPercent": utilization,
        "powerWatts": None,
        "status": "ok" if utilization is not None else "unavailable",
        "source": "ioreg",
    }
    if renderer is not None:
        result["rendererUtilizationPercent"] = renderer
    if tiler is not None:
        result["tilerUtilizationPercent"] = tiler
    if in_use_memory is not None:
        result["inUseSystemMemoryBytes"] = int(in_use_memory)
    if allocated_memory is not None:
        result["allocatedSystemMemoryBytes"] = int(allocated_memory)
    if gpu_core_count is not None:
        result["gpuCoreCount"] = int(gpu_core_count)
    return result


def _ioreg_number(output: str, key: str) -> float | None:
    match = re.search(rf'"{re.escape(key)}"\s*=\s*([0-9.]+)', output)
    if not match:
        return None
    return float(match.group(1))


def model_cache_summary(model_dir: str) -> dict:
    items = model_cache_items(model_dir)
    groups = model_cache_groups(model_dir)
    return {
        "modelDir": str(Path(model_dir).expanduser()),
        "totalBytes": sum(item["sizeBytes"] for item in items),
        "itemCount": len(items),
        "convertedCount": sum(1 for item in items if item["kind"] == "converted"),
        "groupCount": len(groups),
    }


def model_cache(model_dir: str) -> dict:
    items = model_cache_items(model_dir)
    return {
        "modelDir": str(Path(model_dir).expanduser()),
        "totalBytes": sum(item["sizeBytes"] for item in items),
        "items": items,
        "groups": model_cache_groups(model_dir),
    }


def delete_model_cache_item(model_dir: str, item_path: str) -> dict:
    root = Path(model_dir).expanduser().resolve()
    requested = Path(item_path).expanduser()
    if not requested.is_absolute():
        requested = root / requested
    target = requested.resolve(strict=False)

    if target.parent != root:
        raise ValueError(f"Refusing to delete outside model cache: {item_path}")
    if target.suffix.lower() not in MODEL_SUFFIXES:
        raise ValueError(f"Refusing to delete unsupported model cache file: {target.name}")
    if not target.exists():
        raise FileNotFoundError(f"Model cache file does not exist: {target.name}")
    if not target.is_file():
        raise ValueError(f"Model cache item is not a file: {target.name}")

    deleted_bytes = target.stat().st_size
    target.unlink()
    result = model_cache(str(root))
    result["deleted"] = {
        "filename": target.name,
        "path": str(target),
        "sizeBytes": deleted_bytes,
    }
    return result


def delete_model_group_source(model_dir: str, group_id: str) -> dict:
    root = Path(model_dir).expanduser().resolve()
    groups = {group["id"]: group for group in model_cache_groups(str(root))}
    group = groups.get(group_id)
    if group is None:
        raise FileNotFoundError(f"Model group does not exist: {group_id}")
    if not group.get("convertedPath") or not group.get("configPath") or not group.get("sourcePath"):
        raise ValueError(f"Model group {group_id} needs converted weights and config before source removal.")
    if group.get("sourceRemoved"):
        raise ValueError(f"Model group {group_id} source is already removed.")

    source = Path(group["sourcePath"]).resolve(strict=False)
    if source.parent != root or source.suffix.lower() not in SOURCE_MODEL_SUFFIXES:
        raise ValueError(f"Refusing to delete unsupported model source: {group_id}")
    if not source.exists() or not source.is_file():
        raise FileNotFoundError(f"Model source does not exist: {source.name}")

    deleted_bytes = source.stat().st_size
    placeholder = (
        f"{SOURCE_PLACEHOLDER_PREFIX}\n"
        f"original_filename={source.name}\n"
        f"original_size_bytes={deleted_bytes}\n"
        "The matching .safetensors and .yaml files are the installed MLX model.\n"
    )
    source.write_text(placeholder, encoding="utf-8")

    result = model_cache(str(root))
    result["deleted"] = {
        "filename": source.name,
        "path": str(source),
        "sizeBytes": deleted_bytes,
        "replacedWithPlaceholder": True,
    }
    return result


def model_cache_groups(model_dir: str) -> list[dict]:
    root = Path(model_dir).expanduser()
    usage_counts = model_usage_counts(str(root))

    grouped: dict[str, list[Path]] = {}
    if root.exists():
        for path in root.iterdir():
            if path.is_file() and path.suffix.lower() in MODEL_SUFFIXES:
                grouped.setdefault(path.stem, []).append(path)

    groups_by_id = {}
    for stem, paths in sorted(grouped.items(), key=lambda item: item[0].lower()):
        metadata = metadata_for_model_stem(stem) or {}
        group = _model_group_from_paths(
            stem=stem,
            paths=paths,
            metadata=metadata,
            include_empty=False,
            usage_counts=usage_counts,
        )
        if group is None:
            continue
        groups_by_id[stem] = group

    for metadata in model_library_metadata_entries():
        stem = metadata["id"]
        if stem in groups_by_id:
            continue
        groups_by_id[stem] = _model_group_from_paths(
            stem=stem,
            paths=grouped.get(stem, []),
            metadata=metadata,
            include_empty=True,
            usage_counts=usage_counts,
        )

    existing_titles = {group["displayName"] for group in groups_by_id.values()}
    for preset_metadata in _header_preset_metadata_entries():
        if preset_metadata["displayName"] in existing_titles:
            continue
        stem = preset_metadata["modelStem"]
        group = _model_group_from_paths(
            stem=stem,
            paths=grouped.get(stem, []),
            metadata=preset_metadata,
            include_empty=True,
            group_id=f"preset:{preset_metadata['presetID']}",
            usage_counts=usage_counts,
        )
        groups_by_id[group["id"]] = group
        existing_titles.add(group["displayName"])

    return sorted(groups_by_id.values(), key=lambda item: item["displayName"].lower())


def _model_group_from_paths(
    stem: str,
    paths: list[Path],
    metadata: dict,
    include_empty: bool,
    group_id: str | None = None,
    usage_counts: dict[str, int] | None = None,
) -> dict | None:
    source = _first_path_with_suffix(paths, SOURCE_MODEL_SUFFIXES)
    converted = _first_path_with_suffix(paths, {".safetensors"})
    config = _first_path_with_suffix(paths, {".yaml"})
    source_removed = bool(source and _is_source_placeholder(source))
    if not include_empty and converted is None and (source is None or source_removed):
        return None
    source_bytes = 0 if source_removed or source is None else source.stat().st_size
    converted_bytes = converted.stat().st_size if converted else 0
    config_bytes = config.stat().st_size if config else 0
    visible_files = [
        _cache_file_entry(path)
        for path in sorted(paths, key=lambda item: _group_file_sort_key(item))
        if path.suffix.lower() != ".yaml" and not _is_source_placeholder(path)
    ]
    group = _model_group(
        stem=stem,
        metadata=metadata,
        converted=converted is not None,
        has_source=source is not None and not source_removed,
        source_removed=source_removed,
        can_delete_source=bool(source and converted and config and not source_removed),
        total_bytes=sum(path.stat().st_size for path in paths),
        source_bytes=source_bytes,
        converted_bytes=converted_bytes,
        config_bytes=config_bytes,
        source_path=str(source) if source and not source_removed else None,
        converted_path=str(converted) if converted else None,
        config_path=str(config) if config else None,
        usage_count=_usage_count_for_model(stem, metadata, usage_counts or {}),
        files=visible_files,
    )
    if group_id:
        group["id"] = group_id
    return group


def _header_preset_metadata_entries() -> list[dict]:
    from .presets import PRESETS

    entries = []
    for preset in PRESETS.values():
        stem = Path(preset.model_filename).stem
        metadata = dict(metadata_for_model_stem(stem) or {})
        metadata["displayName"] = preset.title
        metadata["summary"] = preset.summary
        metadata["technicalName"] = metadata.get("technicalName") or preset.model_filename
        metadata["modelStem"] = stem
        metadata["modelFilename"] = preset.model_filename
        metadata["presetID"] = preset.id
        entries.append(metadata)
    return entries


def _model_group(
    stem: str,
    metadata: dict,
    converted: bool,
    has_source: bool,
    source_removed: bool,
    can_delete_source: bool,
    total_bytes: int,
    source_bytes: int,
    converted_bytes: int,
    config_bytes: int,
    source_path: str | None,
    converted_path: str | None,
    config_path: str | None,
    usage_count: int,
    files: list[dict],
) -> dict:
    if converted:
        local_state = "installed"
    elif has_source:
        local_state = "downloaded"
    elif source_removed:
        local_state = "source_removed"
    else:
        local_state = "not_downloaded"

    return {
        "id": stem,
        "displayName": metadata.get("displayName", stem),
        "technicalName": metadata.get("technicalName"),
        "architecture": metadata.get("architecture"),
        "backend": metadata.get("backend"),
        "license": metadata.get("license"),
        "sourceURL": metadata.get("sourceURL"),
        "summary": metadata.get("summary"),
        "localState": local_state,
        "converted": converted,
        "hasSource": has_source,
        "sourceRemoved": source_removed,
        "canDeleteSource": can_delete_source,
        "totalBytes": total_bytes,
        "sourceBytes": source_bytes,
        "convertedBytes": converted_bytes,
        "configBytes": config_bytes,
        "sourcePath": source_path,
        "convertedPath": converted_path,
        "configPath": config_path,
        "usageCount": usage_count,
        "files": files,
    }


def _usage_count_for_model(stem: str, metadata: dict, usage_counts: dict[str, int]) -> int:
    candidates = [
        metadata.get("modelFilename"),
        f"{stem}.ckpt",
        f"{stem}.onnx",
        f"{stem}.pth",
        f"{stem}.yaml",
        stem,
    ]
    for candidate in candidates:
        if not candidate:
            continue
        count = usage_counts.get(str(candidate))
        if count is not None:
            return max(0, int(count))
    return 0


def model_cache_items(model_dir: str) -> list[dict]:
    root = Path(model_dir).expanduser()
    if not root.exists():
        return []

    files = [path for path in root.iterdir() if path.is_file() and path.suffix.lower() in MODEL_SUFFIXES]
    stems_with_safetensors = {path.stem for path in files if path.suffix.lower() == ".safetensors"}
    items = []
    for path in sorted(files, key=lambda item: item.name.lower()):
        item = _cache_file_entry(path)
        item["converted"] = item["kind"] == "converted" or path.stem in stems_with_safetensors
        items.append(item)
    return items


def _cache_file_entry(path: Path) -> dict:
    if path.suffix.lower() == ".safetensors":
        kind = "converted"
    elif path.suffix.lower() == ".yaml":
        kind = "config"
    elif _is_source_placeholder(path):
        kind = "source_placeholder"
    else:
        kind = "checkpoint"
    return {
        "filename": path.name,
        "path": str(path),
        "sizeBytes": path.stat().st_size,
        "kind": kind,
        "converted": kind == "converted",
        "modifiedAt": path.stat().st_mtime,
    }


def _first_path_with_suffix(paths: list[Path], suffixes: set[str]) -> Path | None:
    matches = [path for path in paths if path.suffix.lower() in suffixes]
    return sorted(matches, key=lambda item: item.name.lower())[0] if matches else None


def _group_file_sort_key(path: Path) -> tuple[int, str]:
    order = {
        ".ckpt": 0,
        ".pth": 0,
        ".onnx": 0,
        ".safetensors": 1,
        ".yaml": 2,
    }
    return (order.get(path.suffix.lower(), 9), path.name.lower())


def _is_source_placeholder(path: Path) -> bool:
    if path.suffix.lower() not in SOURCE_MODEL_SUFFIXES or not path.exists() or not path.is_file():
        return False
    if path.stat().st_size > 1024:
        return False
    try:
        return path.read_text(encoding="utf-8", errors="ignore").startswith(SOURCE_PLACEHOLDER_PREFIX)
    except Exception:
        return False
