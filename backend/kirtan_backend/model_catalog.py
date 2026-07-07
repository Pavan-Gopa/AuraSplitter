from __future__ import annotations

import logging
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class ModelAsset:
    filename: str
    url: str


@dataclass(frozen=True)
class ModelCatalogEntry:
    id: str
    title: str
    filename: str
    model_type: str
    architecture: str
    backend: str
    summary: str
    expected_stems: tuple[str, ...]
    license: str
    source_url: str
    checkpoint_url: str
    config_filename: str | None = None
    config_url: str | None = None
    target_stem: str | None = None
    scores: dict[str, float] | None = None
    enabled: bool = True
    status: str = "supported"

    @property
    def assets(self) -> tuple[ModelAsset, ...]:
        assets = [ModelAsset(self.filename, self.checkpoint_url)]
        if self.config_filename and self.config_url:
            assets.append(ModelAsset(self.config_filename, self.config_url))
        return tuple(assets)

    @property
    def download_files(self) -> tuple[str, ...]:
        files = [self.filename]
        if self.config_filename:
            files.append(self.config_filename)
        return tuple(files)

    def supported_model_info(self) -> dict:
        return {
            "filename": self.filename,
            "download_files": list(self.download_files),
            "scores": {
                stem: {"SDR": score}
                for stem, score in (self.scores or {}).items()
            },
            "stems": list(self.expected_stems),
            "target_stem": self.target_stem,
        }


def hf_resolve(repo: str, path: str) -> str:
    return f"https://huggingface.co/{repo}/resolve/main/{path}"


MODEL_PACK_ENTRIES: tuple[ModelCatalogEntry, ...] = (
    ModelCatalogEntry(
        id="hyperace_v2_vocal",
        title="HyperACE v2 Vocal",
        filename="bs_roformer_voc_hyperacev2.ckpt",
        config_filename="bs_roformer_voc_hyperacev2.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Modern BS-RoFormer vocal / instrumental split with stronger vocal leaderboard SDR than ViperX 1296.",
        expected_stems=("vocals", "instrumental"),
        target_stem="vocals",
        scores={"vocals": 11.4},
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/pcunwa/BS-Roformer-HyperACE",
        checkpoint_url=hf_resolve("pcunwa/BS-Roformer-HyperACE", "v2_voc/bs_roformer_voc_hyperacev2.ckpt"),
        config_url=hf_resolve("pcunwa/BS-Roformer-HyperACE", "v2_voc/config.yaml"),
    ),
    ModelCatalogEntry(
        id="hyperace_v2_instrumental",
        title="HyperACE v2 Instrumental",
        filename="bs_roformer_inst_hyperacev2.ckpt",
        config_filename="bs_roformer_inst_hyperacev2.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Modern BS-RoFormer focused on the instrumental side of vocal / instrumental separation.",
        expected_stems=("instrumental", "vocals"),
        target_stem="instrumental",
        scores={"instrumental": 17.4},
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/pcunwa/BS-Roformer-HyperACE",
        checkpoint_url=hf_resolve("pcunwa/BS-Roformer-HyperACE", "v2_inst/bs_roformer_inst_hyperacev2.ckpt"),
        config_url=hf_resolve("pcunwa/BS-Roformer-HyperACE", "v2_inst/config.yaml"),
    ),
    ModelCatalogEntry(
        id="leap_xe_vocal",
        title="Leap Xe Vocal",
        filename="bs_leap_xe_voc.ckpt",
        config_filename="bs_roformer_leap_xe_voc.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Leap Xe BS-RoFormer vocal / instrumental split; strong public MVSep candidate.",
        expected_stems=("vocals", "instrumental"),
        target_stem="vocals",
        scores={"vocals": 11.8},
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/pcunwa/BS-Roformer-Leap",
        checkpoint_url=hf_resolve("pcunwa/BS-Roformer-Leap", "Xe/bs_leap_xe_voc.ckpt"),
        config_url=hf_resolve("pcunwa/BS-Roformer-Leap", "Xe/leap_xe_config_voc.yaml"),
    ),
    ModelCatalogEntry(
        id="leap_xe_instrumental",
        title="Leap Xe Instrumental",
        filename="bs_leap_xe_inst.ckpt",
        config_filename="bs_roformer_leap_xe_inst.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Leap Xe BS-RoFormer focused on the instrumental side of vocal / instrumental separation.",
        expected_stems=("instrumental", "vocals"),
        target_stem="instrumental",
        scores={"instrumental": 17.5},
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/pcunwa/BS-Roformer-Leap",
        checkpoint_url=hf_resolve("pcunwa/BS-Roformer-Leap", "Xe/bs_leap_xe_inst.ckpt"),
        config_url=hf_resolve("pcunwa/BS-Roformer-Leap", "Xe/leap_xe_config_inst.yaml"),
    ),
    ModelCatalogEntry(
        id="becruily_deux",
        title="Becruily Deux Vocal / Instrumental",
        filename="becruily_deux.ckpt",
        config_filename="mel_band_roformer_becruily_deux.yaml",
        model_type="MDXC",
        architecture="MelBand RoFormer",
        backend="mlx",
        summary="Two-stem MelBand RoFormer for vocal / instrumental separation. Upstream license is non-commercial.",
        expected_stems=("vocals", "instrumental"),
        license="CC-BY-NC-4.0",
        source_url="https://huggingface.co/becruily/mel-band-roformer-deux",
        checkpoint_url=hf_resolve("becruily/mel-band-roformer-deux", "becruily_deux.ckpt"),
        config_url=hf_resolve("becruily/mel-band-roformer-deux", "config_deux_becruily.yaml"),
    ),
    ModelCatalogEntry(
        id="lead_back_bve_gonza",
        title="Lead / Back BVE Gonza",
        filename="mel_band_roformer_bve_gonza.ckpt",
        config_filename="mel_band_roformer_bve_gonza.yaml",
        model_type="MDXC",
        architecture="MelBand RoFormer",
        backend="mlx",
        summary="Lead vocal / backing vocal separation for karaoke and duet cleanup.",
        expected_stems=("lead", "back"),
        target_stem="lead",
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/Gonzaluigi/Mel-Band-Roformer-BVE-Gonzaluigi",
        checkpoint_url=hf_resolve("Gonzaluigi/Mel-Band-Roformer-BVE-Gonzaluigi", "mel_band_roformer_bve_gonza.ckpt"),
        config_url=hf_resolve("Gonzaluigi/Mel-Band-Roformer-BVE-Gonzaluigi", "config_bve_gonza.yaml"),
    ),
    ModelCatalogEntry(
        id="lead_back_karaoke_anvuew",
        title="Lead / Back Karaoke Anvuew",
        filename="karaoke_bs_roformer_anvuew.ckpt",
        config_filename="karaoke_bs_roformer_anvuew.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Alternative BS-RoFormer karaoke model for lead vocal and backing/instrument bed separation.",
        expected_stems=("lead", "back"),
        target_stem="lead",
        license="GPL-3.0",
        source_url="https://huggingface.co/anvuew/karaoke_bs_roformer",
        checkpoint_url=hf_resolve("anvuew/karaoke_bs_roformer", "karaoke_bs_roformer_anvuew.ckpt"),
        config_url=hf_resolve("anvuew/karaoke_bs_roformer", "karaoke_bs_roformer_anvuew.yaml"),
    ),
    ModelCatalogEntry(
        id="drumsep_mdx23c_5stem",
        title="DrumSep MDX23C 5-Stem",
        filename="drumsep_5stems_mdx23c_jarredou.ckpt",
        config_filename="config_mdx23c_drumsep2025.yaml",
        model_type="MDXC",
        architecture="MDX23C",
        backend="mlx",
        summary="Public DrumSep 5-stem model for kick, snare, toms, hi-hat, and cymbals.",
        expected_stems=("kick", "snare", "toms", "hh", "cymbals"),
        license="MIT mirror metadata; verify upstream terms before redistribution",
        source_url="https://huggingface.co/xavriley/source_separation_mirror",
        checkpoint_url=hf_resolve("xavriley/source_separation_mirror", "drumsep_5stems_mdx23c_jarredou.ckpt"),
        config_url=hf_resolve("xavriley/source_separation_mirror", "config_mdx23c_drumsep2025.yaml"),
    ),
    ModelCatalogEntry(
        id="mega_lead_vocal",
        title="Mega 53 Lead Vocal",
        filename="bs_mega_53stem_lead-vocal_mvsep.ckpt",
        config_filename="bs_roformer_mega_53stem_lead-vocal_mvsep.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Single-target MVSep Mega 53-stem model for lead vocal extraction.",
        expected_stems=("lead-vocal", "other"),
        target_stem="lead-vocal",
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/noblebarkrr/BS-Roformer-MVSep-Mega-53-stems",
        checkpoint_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_lead-vocal_mvsep.ckpt"),
        config_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_lead-vocal_mvsep_config.yaml"),
    ),
    ModelCatalogEntry(
        id="mega_back_vocal",
        title="Mega 53 Back Vocal",
        filename="bs_mega_53stem_back-vocal_mvsep.ckpt",
        config_filename="bs_roformer_mega_53stem_back-vocal_mvsep.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Single-target MVSep Mega 53-stem model for backing vocal extraction.",
        expected_stems=("back-vocal", "other"),
        target_stem="back-vocal",
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/noblebarkrr/BS-Roformer-MVSep-Mega-53-stems",
        checkpoint_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_back-vocal_mvsep.ckpt"),
        config_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_back-vocal_mvsep_config.yaml"),
    ),
    ModelCatalogEntry(
        id="mega_drums",
        title="Mega 53 Drums",
        filename="bs_mega_53stem_drums_mvsep.ckpt",
        config_filename="bs_roformer_mega_53stem_drums_mvsep.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Single-target MVSep Mega 53-stem model for drum bed extraction.",
        expected_stems=("drums", "other"),
        target_stem="drums",
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/noblebarkrr/BS-Roformer-MVSep-Mega-53-stems",
        checkpoint_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_drums_mvsep.ckpt"),
        config_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_drums_mvsep_config.yaml"),
    ),
    ModelCatalogEntry(
        id="mega_sitar",
        title="Mega 53 Sitar",
        filename="bs_mega_53stem_sitar_mvsep.ckpt",
        config_filename="bs_roformer_mega_53stem_sitar_mvsep.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Single-target MVSep Mega 53-stem model for sitar-like instrument extraction.",
        expected_stems=("sitar", "other"),
        target_stem="sitar",
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/noblebarkrr/BS-Roformer-MVSep-Mega-53-stems",
        checkpoint_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_sitar_mvsep.ckpt"),
        config_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_sitar_mvsep_config.yaml"),
    ),
    ModelCatalogEntry(
        id="mega_piano",
        title="Mega 53 Piano",
        filename="bs_mega_53stem_piano_mvsep.ckpt",
        config_filename="bs_roformer_mega_53stem_piano_mvsep.yaml",
        model_type="MDXC",
        architecture="BS-RoFormer",
        backend="mlx",
        summary="Single-target MVSep Mega 53-stem model for piano extraction.",
        expected_stems=("piano", "other"),
        target_stem="piano",
        license="community checkpoint; verify upstream terms before redistribution",
        source_url="https://huggingface.co/noblebarkrr/BS-Roformer-MVSep-Mega-53-stems",
        checkpoint_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_piano_mvsep.ckpt"),
        config_url=hf_resolve("noblebarkrr/BS-Roformer-MVSep-Mega-53-stems", "v1/bs_mega_53stem_piano_mvsep_config.yaml"),
    ),
)

EXPERIMENTAL_MODEL_CANDIDATES: tuple[ModelCatalogEntry, ...] = (
    ModelCatalogEntry(
        id="polarformer_vocal",
        title="BS PolarFormer 124-band",
        filename="model_bs_polarformer_float16.ckpt",
        config_filename="model_bs_polarformer_float16.yaml",
        model_type="PolarFormer",
        architecture="BS-PolarFormer",
        backend="requires_native_polarformer_or_onnx",
        summary="Leaderboard vocal / instrumental candidate. Needs a PolarFormer/PoPE backend or an ONNX/CoreML runner.",
        expected_stems=("vocals", "instrumental"),
        scores={"vocals": 12.0, "instrumental": 18.3},
        license="MIT",
        source_url="https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/tag/v1.0.20",
        checkpoint_url="https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.20/model_bs_polarformer_float16.ckpt",
        config_url="https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.20/model_bs_polarformer_float16.yaml",
        enabled=False,
        status="requires_backend",
    ),
    ModelCatalogEntry(
        id="drumsep_onnx",
        title="DrumSep ONNX 4-Stem",
        filename="drumsep.onnx",
        model_type="ONNX",
        architecture="DrumSep ONNX",
        backend="requires_onnxruntime_coreml",
        summary="Public DrumSep ONNX model for kick, snare, cymbals, and toms. Needs a separate ONNX/CoreML backend.",
        expected_stems=("kick", "snare", "cymbals", "toms"),
        license="MIT",
        source_url="https://huggingface.co/gridshiftstudio/drumsep-onnx",
        checkpoint_url=hf_resolve("gridshiftstudio/drumsep-onnx", "drumsep.onnx"),
        enabled=False,
        status="requires_backend",
    ),
)

MODEL_PACK_BY_FILENAME = {entry.filename: entry for entry in MODEL_PACK_ENTRIES}
MODEL_PACK_BY_ID = {entry.id: entry for entry in MODEL_PACK_ENTRIES}
EXPERIMENTAL_BY_FILENAME = {entry.filename: entry for entry in EXPERIMENTAL_MODEL_CANDIDATES}


def get_model_pack_entry(filename: str) -> ModelCatalogEntry | None:
    return MODEL_PACK_BY_FILENAME.get(filename)


def display_name_for_model(filename: str) -> str | None:
    entry = MODEL_PACK_BY_FILENAME.get(filename) or EXPERIMENTAL_BY_FILENAME.get(filename)
    return entry.title if entry else None


def merge_model_pack(grouped: dict) -> dict:
    merged = {key: dict(value) for key, value in grouped.items()}
    for entry in MODEL_PACK_ENTRIES:
        if not entry.enabled:
            continue
        models = dict(merged.get(entry.model_type, {}))
        models[entry.title] = entry.supported_model_info()
        merged[entry.model_type] = models
    return merged


def attach_model_pack_to_separator(separator) -> None:
    if not hasattr(separator, "list_supported_model_files"):
        return

    original = separator.list_supported_model_files

    def patched_list_supported_model_files():
        return merge_model_pack(original())

    separator.list_supported_model_files = patched_list_supported_model_files


def ensure_model_pack_assets(
    filename: str,
    model_dir: str,
    logger: logging.Logger,
    downloader: Callable[[str, Path, logging.Logger], None] | None = None,
) -> ModelCatalogEntry | None:
    entry = MODEL_PACK_BY_FILENAME.get(filename)
    if not entry:
        experimental = EXPERIMENTAL_BY_FILENAME.get(filename)
        if experimental:
            raise ValueError(
                f"{experimental.title} is cataloged but not runnable yet: {experimental.summary}"
            )
        return None
    if entry.backend != "mlx" or not entry.enabled:
        raise ValueError(f"{entry.title} is not enabled for the MLX backend")

    destination_dir = Path(model_dir).expanduser()
    destination_dir.mkdir(parents=True, exist_ok=True)
    for asset in entry.assets:
        output_path = destination_dir / asset.filename
        if output_path.is_file():
            logger.debug("Model pack asset already exists at %s", output_path)
            continue
        logger.info("Downloading model pack asset %s from %s", asset.filename, asset.url)
        (downloader or _download_asset)(asset.url, output_path, logger)
    return entry


def _download_asset(url: str, output_path: Path, logger: logging.Logger) -> None:
    import requests

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{output_path.name}.", suffix=".download", dir=str(output_path.parent))
    os.close(fd)
    temp_path = Path(temp_name)
    try:
        with requests.get(url, stream=True, timeout=300) as response:
            if response.status_code != 200:
                raise RuntimeError(f"Failed to download {url}: HTTP {response.status_code}")
            with open(temp_path, "wb") as handle:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        handle.write(chunk)
        temp_path.replace(output_path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        logger.exception("Failed to download model pack asset %s", url)
        raise
