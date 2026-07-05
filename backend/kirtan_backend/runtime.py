from __future__ import annotations

import os
import platform
import re
import subprocess
import time
from pathlib import Path


MODEL_SUFFIXES = {".ckpt", ".onnx", ".pth", ".yaml", ".safetensors"}


def runtime_stats(model_dir: str) -> dict:
    return {
        "timestamp": time.time(),
        "cpu": cpu_stats(),
        "memory": memory_stats(),
        "process": process_stats(os.getpid()),
        "gpu": gpu_stats(),
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
        "status": sample.get("status", "unavailable"),
        "source": sample.get("source", "powermetrics"),
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
    return result


def _ioreg_number(output: str, key: str) -> float | None:
    match = re.search(rf'"{re.escape(key)}"\s*=\s*([0-9.]+)', output)
    if not match:
        return None
    return float(match.group(1))


def model_cache_summary(model_dir: str) -> dict:
    items = model_cache_items(model_dir)
    return {
        "modelDir": str(Path(model_dir).expanduser()),
        "totalBytes": sum(item["sizeBytes"] for item in items),
        "itemCount": len(items),
        "convertedCount": sum(1 for item in items if item["kind"] == "converted"),
    }


def model_cache(model_dir: str) -> dict:
    items = model_cache_items(model_dir)
    return {
        "modelDir": str(Path(model_dir).expanduser()),
        "totalBytes": sum(item["sizeBytes"] for item in items),
        "items": items,
    }


def model_cache_items(model_dir: str) -> list[dict]:
    root = Path(model_dir).expanduser()
    if not root.exists():
        return []

    files = [path for path in root.iterdir() if path.is_file() and path.suffix.lower() in MODEL_SUFFIXES]
    stems_with_safetensors = {path.stem for path in files if path.suffix.lower() == ".safetensors"}
    items = []
    for path in sorted(files, key=lambda item: item.name.lower()):
        if path.suffix.lower() == ".safetensors":
            kind = "converted"
        elif path.suffix.lower() == ".yaml":
            kind = "config"
        else:
            kind = "checkpoint"
        items.append(
            {
                "filename": path.name,
                "path": str(path),
                "sizeBytes": path.stat().st_size,
                "kind": kind,
                "converted": kind == "converted" or path.stem in stems_with_safetensors,
                "modifiedAt": path.stat().st_mtime,
            }
        )
    return items
