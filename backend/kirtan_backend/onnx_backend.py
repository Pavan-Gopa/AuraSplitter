from __future__ import annotations

import logging
import subprocess
from pathlib import Path


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
