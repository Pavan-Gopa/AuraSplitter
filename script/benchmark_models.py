#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[1]
VENV_PYTHON = ROOT_DIR / ".venv/bin/python"
if VENV_PYTHON.is_file() and Path(sys.executable).resolve() != VENV_PYTHON.resolve():
    os.execv(str(VENV_PYTHON), [str(VENV_PYTHON), *sys.argv])

sys.path.insert(0, str(ROOT_DIR / "backend"))

from kirtan_backend.engine import MlxSeparatorEngine  # noqa: E402
from kirtan_backend.jobs import SeparationJob  # noqa: E402
from kirtan_backend.presets import PRESETS, resolve_model_filename  # noqa: E402
from kirtan_backend.process_presets import PROCESS_PRESETS  # noqa: E402
from kirtan_backend.server import default_model_dir  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run KirtanSplitter model/process preset benchmarks on one audio file."
    )
    parser.add_argument("input", help="Audio file to benchmark.")
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Benchmark output directory. Defaults to ~/Library/Application Support/KirtanSplitter/benchmarks/<timestamp>.",
    )
    parser.add_argument(
        "--model-dir",
        default=default_model_dir(),
        help="Model cache directory.",
    )
    parser.add_argument(
        "--presets",
        default="all",
        help="Comma-separated model preset IDs, or 'all'.",
    )
    parser.add_argument(
        "--process-presets",
        default="builtin.fast,builtin.heavy,builtin.extreme",
        help="Comma-separated process preset IDs.",
    )
    parser.add_argument(
        "--stop-on-error",
        action="store_true",
        help="Stop at the first failed model instead of continuing.",
    )
    args = parser.parse_args()

    input_path = Path(args.input).expanduser()
    if not input_path.is_file():
        raise SystemExit(f"Input file does not exist: {input_path}")

    output_dir = Path(args.output_dir).expanduser() if args.output_dir else default_output_dir()
    output_dir.mkdir(parents=True, exist_ok=True)
    results_path = output_dir / "benchmark_results.jsonl"

    model_preset_ids = list(PRESETS) if args.presets == "all" else split_csv(args.presets)
    process_preset_ids = split_csv(args.process_presets)
    validate_ids(model_preset_ids, process_preset_ids)

    engine = MlxSeparatorEngine(str(Path(args.model_dir).expanduser()))
    print(f"Input: {input_path}")
    print(f"Output: {output_dir}")
    print(f"Model presets: {len(model_preset_ids)}")
    print(f"Process presets: {', '.join(process_preset_ids)}")
    print("Starting benchmarks. This can take many hours and may download model files.")

    failures = 0
    with results_path.open("a", encoding="utf-8") as results_file:
        for model_preset_id in model_preset_ids:
            model_filename = resolve_model_filename(model_preset_id, None)
            model_preset = PRESETS[model_preset_id]
            for process_preset_id in process_preset_ids:
                process_preset = PROCESS_PRESETS[process_preset_id]
                run_output_dir = output_dir / safe_path_part(model_preset_id) / safe_path_part(process_preset_id)
                run_output_dir.mkdir(parents=True, exist_ok=True)
                params = {
                    "inputPath": str(input_path),
                    "outputDir": str(run_output_dir),
                    "preset": model_preset_id,
                    "processPresetID": process_preset_id,
                    "processPresetTitle": process_preset["title"],
                    **process_preset["settings"],
                }
                job = SeparationJob.from_params(params, model_filename=model_filename)
                print(f"\n[{model_preset.title} / {process_preset['title']}]")
                started = time.time()
                try:
                    summary = engine.separate(job, progress=print_progress)
                    row = {
                        "status": "ok",
                        "modelPresetID": model_preset_id,
                        "modelPresetTitle": model_preset.title,
                        "modelFilename": model_filename,
                        "processPresetID": process_preset_id,
                        "processPresetTitle": process_preset["title"],
                        "elapsedSeconds": summary.get("elapsedSeconds"),
                        "fileCount": len(summary.get("files") or []),
                        "outputDir": str(run_output_dir),
                    }
                    print(f"Completed in {summary.get('elapsedSeconds')}s")
                except Exception as exc:
                    failures += 1
                    row = {
                        "status": "error",
                        "modelPresetID": model_preset_id,
                        "modelPresetTitle": model_preset.title,
                        "modelFilename": model_filename,
                        "processPresetID": process_preset_id,
                        "processPresetTitle": process_preset["title"],
                        "elapsedSeconds": round(time.time() - started, 3),
                        "error": f"{type(exc).__name__}: {exc}",
                        "outputDir": str(run_output_dir),
                    }
                    print(row["error"])
                    if args.stop_on_error:
                        results_file.write(json.dumps(row, ensure_ascii=False) + "\n")
                        return 1
                results_file.write(json.dumps(row, ensure_ascii=False) + "\n")
                results_file.flush()

    print(f"\nBenchmark results: {results_path}")
    return 1 if failures else 0


def print_progress(stage: str, message: str, progress: float, runtime: dict | None = None):
    percent = int(progress * 100)
    print(f"{percent:3d}% {stage}: {message}")


def default_output_dir() -> Path:
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    return (
        Path.home()
        / "Library/Application Support/KirtanSplitter/benchmarks"
        / timestamp
    )


def split_csv(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def validate_ids(model_preset_ids: list[str], process_preset_ids: list[str]):
    unknown_models = [preset_id for preset_id in model_preset_ids if preset_id not in PRESETS]
    unknown_process = [preset_id for preset_id in process_preset_ids if preset_id not in PROCESS_PRESETS]
    if unknown_models:
        raise SystemExit(f"Unknown model preset IDs: {', '.join(unknown_models)}")
    if unknown_process:
        raise SystemExit(f"Unknown process preset IDs: {', '.join(unknown_process)}")


def safe_path_part(value: str) -> str:
    return "".join(character if character.isalnum() or character in "-_." else "_" for character in value)


if __name__ == "__main__":
    raise SystemExit(main())
