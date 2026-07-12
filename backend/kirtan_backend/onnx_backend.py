from __future__ import annotations

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
    return None
