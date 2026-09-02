"""KirtanSplitter Python backend."""

from .mlx_compat import (
    apply_mlx_audio_io_app_bundle_compat,
    apply_mlx_audio_separator_silent_audio_compat,
)
from .protocol import BackendRequest, handle_request

apply_mlx_audio_io_app_bundle_compat()
apply_mlx_audio_separator_silent_audio_compat()

__all__ = ["BackendRequest", "handle_request"]
