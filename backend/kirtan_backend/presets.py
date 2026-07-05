from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SeparationPreset:
    id: str
    title: str
    model_filename: str
    summary: str
    expected_stems: tuple[str, ...]

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "title": self.title,
            "modelFilename": self.model_filename,
            "summary": self.summary,
            "expectedStems": list(self.expected_stems),
        }


PRESETS: dict[str, SeparationPreset] = {
    "kirtan_pro": SeparationPreset(
        id="kirtan_pro",
        title="Kirtan Pro",
        model_filename="BS-Roformer-SW.ckpt",
        summary="6-stem RoFormer split for vocals, drums, bass, guitar, piano, and other instruments.",
        expected_stems=("vocals", "drums", "bass", "guitar", "piano", "other"),
    ),
    "vocal_clean": SeparationPreset(
        id="vocal_clean",
        title="Clean Vocal / Instrumental",
        model_filename="model_bs_roformer_ep_368_sdr_12.9628.ckpt",
        summary="High-quality BS-RoFormer vocal isolation for noisy live recordings.",
        expected_stems=("vocals", "instrumental"),
    ),
    "viperx_vocal": SeparationPreset(
        id="viperx_vocal",
        title="ViperX Vocal 1296",
        model_filename="model_bs_roformer_ep_368_sdr_12.9628.ckpt",
        summary="BS-Roformer-Viperx-1296 vocal / instrumental split.",
        expected_stems=("vocals", "instrumental"),
    ),
    "viperx_karaoke": SeparationPreset(
        id="viperx_karaoke",
        title="ViperX Karaoke Aufr33",
        model_filename="mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt",
        summary="MB-Ro-Kara-AuFR33-Viperx karaoke split for vocal and backing separation.",
        expected_stems=("vocals", "instrumental"),
    ),
    "instrument_bleed": SeparationPreset(
        id="instrument_bleed",
        title="Instrument Bleed Control",
        model_filename="mel_band_roformer_instrumental_instv7n_gabox.ckpt",
        summary="MelBand RoFormer instrumental model useful when vocal bleed remains in instrument mics.",
        expected_stems=("instrumental", "vocals"),
    ),
    "drum_focus": SeparationPreset(
        id="drum_focus",
        title="Drums / No Drums",
        model_filename="kuielab_a_drums.onnx",
        summary="Fast drum extraction fallback for tabla, pakhawaj, and percussion cleanup.",
        expected_stems=("drums", "no drums"),
    ),
}


def preset_list() -> list[dict]:
    return [preset.to_dict() for preset in PRESETS.values()]


def resolve_model_filename(preset_id: str | None, explicit_model: str | None) -> str:
    if explicit_model:
        return explicit_model
    if preset_id and preset_id in PRESETS:
        return PRESETS[preset_id].model_filename
    return PRESETS["kirtan_pro"].model_filename
