from __future__ import annotations

from dataclasses import dataclass

from .model_catalog import MODEL_PACK_BY_ID


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
        title="Kirtan Clean Split",
        model_filename="model_bs_roformer_ep_317_sdr_12.9755.ckpt",
        summary="BS-Roformer-Viperx-1297 vocal / instrumental split for clean vocal isolation.",
        expected_stems=("vocals", "instrumental"),
    ),
    "viperx_vocal": SeparationPreset(
        id="viperx_vocal",
        title="Kirtan Vocal Classic",
        model_filename="model_bs_roformer_ep_368_sdr_12.9628.ckpt",
        summary="BS-Roformer-Viperx-1296 vocal / instrumental split.",
        expected_stems=("vocals", "instrumental"),
    ),
    "viperx_karaoke": SeparationPreset(
        id="viperx_karaoke",
        title="Kirtan Karaoke Classic",
        model_filename="mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt",
        summary="MB-Ro-Kara-AuFR33-Viperx karaoke split for vocal and backing separation.",
        expected_stems=("vocals", "instrumental"),
    ),
    "instrument_bleed": SeparationPreset(
        id="instrument_bleed",
        title="Kirtan Instrument Clean",
        model_filename="mel_band_roformer_instrumental_instv7n_gabox.ckpt",
        summary="MelBand RoFormer instrumental model useful when vocal bleed remains in instrument mics.",
        expected_stems=("instrumental", "vocals"),
    ),
    "drum_focus": SeparationPreset(
        id="drum_focus",
        title="Kirtan Drum Classic",
        model_filename="kuielab_a_drums.onnx",
        summary="Fast drum extraction fallback for tabla, pakhawaj, and percussion cleanup.",
        expected_stems=("drums", "no drums"),
    ),
    "hyperace_v2_vocal": SeparationPreset(
        id="hyperace_v2_vocal",
        title=MODEL_PACK_BY_ID["hyperace_v2_vocal"].title,
        model_filename=MODEL_PACK_BY_ID["hyperace_v2_vocal"].filename,
        summary=MODEL_PACK_BY_ID["hyperace_v2_vocal"].summary,
        expected_stems=MODEL_PACK_BY_ID["hyperace_v2_vocal"].expected_stems,
    ),
    "hyperace_v2_instrumental": SeparationPreset(
        id="hyperace_v2_instrumental",
        title=MODEL_PACK_BY_ID["hyperace_v2_instrumental"].title,
        model_filename=MODEL_PACK_BY_ID["hyperace_v2_instrumental"].filename,
        summary=MODEL_PACK_BY_ID["hyperace_v2_instrumental"].summary,
        expected_stems=MODEL_PACK_BY_ID["hyperace_v2_instrumental"].expected_stems,
    ),
    "leap_xe_vocal": SeparationPreset(
        id="leap_xe_vocal",
        title=MODEL_PACK_BY_ID["leap_xe_vocal"].title,
        model_filename=MODEL_PACK_BY_ID["leap_xe_vocal"].filename,
        summary=MODEL_PACK_BY_ID["leap_xe_vocal"].summary,
        expected_stems=MODEL_PACK_BY_ID["leap_xe_vocal"].expected_stems,
    ),
    "leap_xe_instrumental": SeparationPreset(
        id="leap_xe_instrumental",
        title=MODEL_PACK_BY_ID["leap_xe_instrumental"].title,
        model_filename=MODEL_PACK_BY_ID["leap_xe_instrumental"].filename,
        summary=MODEL_PACK_BY_ID["leap_xe_instrumental"].summary,
        expected_stems=MODEL_PACK_BY_ID["leap_xe_instrumental"].expected_stems,
    ),
    "becruily_deux": SeparationPreset(
        id="becruily_deux",
        title=MODEL_PACK_BY_ID["becruily_deux"].title,
        model_filename=MODEL_PACK_BY_ID["becruily_deux"].filename,
        summary=MODEL_PACK_BY_ID["becruily_deux"].summary,
        expected_stems=MODEL_PACK_BY_ID["becruily_deux"].expected_stems,
    ),
    "lead_back_bve_gonza": SeparationPreset(
        id="lead_back_bve_gonza",
        title=MODEL_PACK_BY_ID["lead_back_bve_gonza"].title,
        model_filename=MODEL_PACK_BY_ID["lead_back_bve_gonza"].filename,
        summary=MODEL_PACK_BY_ID["lead_back_bve_gonza"].summary,
        expected_stems=MODEL_PACK_BY_ID["lead_back_bve_gonza"].expected_stems,
    ),
    "lead_back_karaoke_anvuew": SeparationPreset(
        id="lead_back_karaoke_anvuew",
        title=MODEL_PACK_BY_ID["lead_back_karaoke_anvuew"].title,
        model_filename=MODEL_PACK_BY_ID["lead_back_karaoke_anvuew"].filename,
        summary=MODEL_PACK_BY_ID["lead_back_karaoke_anvuew"].summary,
        expected_stems=MODEL_PACK_BY_ID["lead_back_karaoke_anvuew"].expected_stems,
    ),
    "drumsep_mdx23c_5stem": SeparationPreset(
        id="drumsep_mdx23c_5stem",
        title=MODEL_PACK_BY_ID["drumsep_mdx23c_5stem"].title,
        model_filename=MODEL_PACK_BY_ID["drumsep_mdx23c_5stem"].filename,
        summary=MODEL_PACK_BY_ID["drumsep_mdx23c_5stem"].summary,
        expected_stems=MODEL_PACK_BY_ID["drumsep_mdx23c_5stem"].expected_stems,
    ),
    "mega_lead_vocal": SeparationPreset(
        id="mega_lead_vocal",
        title=MODEL_PACK_BY_ID["mega_lead_vocal"].title,
        model_filename=MODEL_PACK_BY_ID["mega_lead_vocal"].filename,
        summary=MODEL_PACK_BY_ID["mega_lead_vocal"].summary,
        expected_stems=MODEL_PACK_BY_ID["mega_lead_vocal"].expected_stems,
    ),
    "mega_back_vocal": SeparationPreset(
        id="mega_back_vocal",
        title=MODEL_PACK_BY_ID["mega_back_vocal"].title,
        model_filename=MODEL_PACK_BY_ID["mega_back_vocal"].filename,
        summary=MODEL_PACK_BY_ID["mega_back_vocal"].summary,
        expected_stems=MODEL_PACK_BY_ID["mega_back_vocal"].expected_stems,
    ),
    "mega_drums": SeparationPreset(
        id="mega_drums",
        title=MODEL_PACK_BY_ID["mega_drums"].title,
        model_filename=MODEL_PACK_BY_ID["mega_drums"].filename,
        summary=MODEL_PACK_BY_ID["mega_drums"].summary,
        expected_stems=MODEL_PACK_BY_ID["mega_drums"].expected_stems,
    ),
    "mega_sitar": SeparationPreset(
        id="mega_sitar",
        title=MODEL_PACK_BY_ID["mega_sitar"].title,
        model_filename=MODEL_PACK_BY_ID["mega_sitar"].filename,
        summary=MODEL_PACK_BY_ID["mega_sitar"].summary,
        expected_stems=MODEL_PACK_BY_ID["mega_sitar"].expected_stems,
    ),
    "mega_piano": SeparationPreset(
        id="mega_piano",
        title=MODEL_PACK_BY_ID["mega_piano"].title,
        model_filename=MODEL_PACK_BY_ID["mega_piano"].filename,
        summary=MODEL_PACK_BY_ID["mega_piano"].summary,
        expected_stems=MODEL_PACK_BY_ID["mega_piano"].expected_stems,
    ),
    "demucs_onnx_stems": SeparationPreset(
        id="demucs_onnx_stems",
        title=MODEL_PACK_BY_ID["demucs_onnx_stems"].title,
        model_filename=MODEL_PACK_BY_ID["demucs_onnx_stems"].filename,
        summary=MODEL_PACK_BY_ID["demucs_onnx_stems"].summary,
        expected_stems=MODEL_PACK_BY_ID["demucs_onnx_stems"].expected_stems,
    ),
    "demucs_onnx_six_stems": SeparationPreset(
        id="demucs_onnx_six_stems",
        title=MODEL_PACK_BY_ID["demucs_onnx_six_stems"].title,
        model_filename=MODEL_PACK_BY_ID["demucs_onnx_six_stems"].filename,
        summary=MODEL_PACK_BY_ID["demucs_onnx_six_stems"].summary,
        expected_stems=MODEL_PACK_BY_ID["demucs_onnx_six_stems"].expected_stems,
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
