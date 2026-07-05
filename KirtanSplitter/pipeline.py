"""
Pipeline оркестратор — многоступенчатое разделение киртана.
Каждая ступень использует свою BSRoformer модель.
Прогресс передаётся через callback для обновления UI.
"""

import json
import time
from pathlib import Path
from dataclasses import dataclass, field
from typing import Callable, Optional
import mlx.core as mx

from bsroformer_mlx import BSRoformer, load_weights_from_ckpt
from audio_inference import separate_track


# ---------------------------------------------------------------------------
# Конфигурация модели
# ---------------------------------------------------------------------------

@dataclass
class ModelConfig:
    name: str
    ckpt_path: str
    stem_names: list[str]
    n_fft: int = 2048
    hop_length: int = 441
    dim: int = 512
    num_heads: int = 8
    depth: int = 12
    num_sources: int = 1
    stereo: bool = True
    description: str = ""


# Стандартные конфигурации для популярных BSRoformer чекпоинтов
KNOWN_MODELS = {
    # Вокал / Инструменты
    "bs_roformer_vocals": ModelConfig(
        name="BS-RoFormer Vocals",
        ckpt_path="models/model_bs_roformer_ep_317_sdr_12.9755.ckpt",
        stem_names=["vocals", "instrumental"],
        dim=512, depth=12, num_sources=2,
        description="Отделяет вокал от инструментов. SDR ~12.97 dB.",
    ),
    # Только вокал (высокое качество)
    "bs_roformer_vocals_hq": ModelConfig(
        name="BS-RoFormer Vocals HQ",
        ckpt_path="models/model_bs_roformer_ep_368_sdr_12.9628.ckpt",
        stem_names=["vocals", "instrumental"],
        dim=768, depth=12, num_sources=2,
        description="Более тяжёлая модель, чуть лучше качество.",
    ),
    # ДрAms
    "bs_roformer_drums": ModelConfig(
        name="BS-RoFormer Drums",
        ckpt_path="models/model_drums_bs_roformer_ep_17_sdr_10.5096.ckpt",
        stem_names=["drums", "no_drums"],
        dim=512, depth=12, num_sources=2,
        description="Отделяет барабаны (табла для киртана).",
    ),
    # Mel-специализированная для вокала
    "bs_roformer_mel_vocals": ModelConfig(
        name="BS-RoFormer Mel Vocals",
        ckpt_path="models/mel_band_roformer_vocals_ep_937_sdr_10.56.ckpt",
        stem_names=["lead_vocals", "backing_vocals"],
        dim=384, depth=8, num_sources=2,
        description="Разделяет основной и бэк-вокал.",
    ),
    # 6-stem
    "bs_roformer_6stem": ModelConfig(
        name="BS-RoFormer 6-Stem",
        ckpt_path="models/bs_roformer_6stems.ckpt",
        stem_names=["vocals", "drums", "bass", "other", "piano", "guitar"],
        dim=512, depth=12, num_sources=6,
        description="Полное разделение на 6 источников.",
    ),
}


# ---------------------------------------------------------------------------
# Ступень пайплайна
# ---------------------------------------------------------------------------

@dataclass
class PipelineStage:
    """Одна ступень разделения: входной файл → список выходных stems."""
    stage_name: str
    model_key: str          # ключ из KNOWN_MODELS
    input_stem: str         # какой stem из предыдущей ступени обрабатываем
    output_stems: list[str] # какие stems ожидаем на выходе
    enabled: bool = True


# ---------------------------------------------------------------------------
# Пресеты для разных сценариев
# ---------------------------------------------------------------------------

KIRTAN_PIPELINE = [
    PipelineStage(
        stage_name="1. Вокал / Инструменты",
        model_key="bs_roformer_vocals",
        input_stem="mix",
        output_stems=["vocals", "instrumental"],
    ),
    PipelineStage(
        stage_name="2. Вокал: основной / бэк",
        model_key="bs_roformer_mel_vocals",
        input_stem="vocals",
        output_stems=["lead_vocals", "backing_vocals"],
    ),
    PipelineStage(
        stage_name="3. Инструменты: табла / без-табла",
        model_key="bs_roformer_drums",
        input_stem="instrumental",
        output_stems=["drums", "no_drums"],
    ),
]

QUICK_PIPELINE = [
    PipelineStage(
        stage_name="1. Вокал / Инструменты",
        model_key="bs_roformer_vocals",
        input_stem="mix",
        output_stems=["vocals", "instrumental"],
    ),
]

FULL_PIPELINE = [
    PipelineStage(
        stage_name="1. Полное разделение (6 stems)",
        model_key="bs_roformer_6stem",
        input_stem="mix",
        output_stems=["vocals", "drums", "bass", "other", "piano", "guitar"],
    ),
]


# ---------------------------------------------------------------------------
# Pipeline Runner
# ---------------------------------------------------------------------------

@dataclass
class PipelineResult:
    success: bool
    stems: dict[str, str] = field(default_factory=dict)  # name → file path
    error: Optional[str] = None
    total_time: float = 0.0


class KirtanPipeline:
    """
    Основной оркестратор. Загружает модели по мере необходимости,
    выполняет ступени последовательно, управляет кэшем моделей.
    """

    def __init__(
        self,
        models_dir: str = "models",
        chunk_seconds: float = 30.0,
    ):
        self.models_dir = Path(models_dir)
        self.chunk_seconds = chunk_seconds
        self._model_cache: dict[str, BSRoformer] = {}

    def _load_model(self, model_key: str) -> BSRoformer:
        """Ленивая загрузка модели с кэшированием."""
        if model_key in self._model_cache:
            return self._model_cache[model_key]

        cfg = KNOWN_MODELS[model_key]
        ckpt_path = self.models_dir / cfg.ckpt_path.split("/")[-1]

        if not ckpt_path.exists():
            raise FileNotFoundError(
                f"Чекпоинт не найден: {ckpt_path}\n"
                f"Скачайте с HuggingFace: https://huggingface.co/TRvlvr/model_repo"
            )

        model = BSRoformer(
            n_fft=cfg.n_fft,
            hop_length=cfg.hop_length,
            num_sources=cfg.num_sources,
            dim=cfg.dim,
            num_heads=cfg.num_heads,
            depth=cfg.depth,
            stereo=cfg.stereo,
        )
        model = load_weights_from_ckpt(model, str(ckpt_path))
        # Переводим в eval mode (отключаем dropout)
        model.eval()

        # Прогреваем модель (JIT компиляция графа вычислений)
        print(f"Прогрев модели {cfg.name}...")
        dummy = mx.zeros((1, 2, cfg.n_fft // 2 + 1, 10, 2))
        _ = model(dummy)
        mx.eval(_)

        self._model_cache[model_key] = model
        return model

    def unload_model(self, model_key: str):
        """Выгружаем модель из памяти (важно на Mac с ограниченной unified memory)."""
        if model_key in self._model_cache:
            del self._model_cache[model_key]
            # MLX не имеет explicit gc, но Python gc подберёт

    def run(
        self,
        input_path: str,
        output_dir: str,
        stages: list[PipelineStage],
        progress_cb: Optional[Callable[[str, float], None]] = None,
    ) -> PipelineResult:
        """
        Запускаем полный пайплайн.
        
        progress_cb(stage_name, 0.0–1.0) вызывается для обновления UI.
        """
        start_time = time.time()
        stems: dict[str, str] = {"mix": input_path}
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        try:
            for stage_idx, stage in enumerate(stages):
                if not stage.enabled:
                    continue

                print(f"\n{'='*50}")
                print(f"Ступень: {stage.stage_name}")
                print(f"{'='*50}")

                # Проверяем что входной stem доступен
                if stage.input_stem not in stems:
                    raise ValueError(
                        f"Stem '{stage.input_stem}' не найден. "
                        f"Доступны: {list(stems.keys())}"
                    )

                input_file = stems[stage.input_stem]
                cfg = KNOWN_MODELS[stage.model_key]

                # Загружаем модель
                model = self._load_model(stage.model_key)

                # Прогресс-колбэк для этой ступени
                def stage_progress(p: float):
                    if progress_cb:
                        # Нормализуем прогресс по всему пайплайну
                        stage_weight = 1.0 / len(stages)
                        global_progress = (stage_idx + p) * stage_weight
                        progress_cb(stage.stage_name, global_progress)

                # Запускаем разделение
                stage_output_dir = output_dir / f"stage_{stage_idx + 1}"
                output_paths = separate_track(
                    model=model,
                    input_path=input_file,
                    output_dir=str(stage_output_dir),
                    stem_names=stage.output_stems,
                    n_fft=cfg.n_fft,
                    hop_length=cfg.hop_length,
                    chunk_seconds=self.chunk_seconds,
                    progress_cb=stage_progress,
                )

                # Добавляем результаты в словарь stems
                for name, path in zip(stage.output_stems, output_paths):
                    stems[name] = path

                # Выгружаем модель если она больше не нужна
                # (проверяем нужна ли она в следующих ступенях)
                needed_later = any(
                    s.model_key == stage.model_key
                    for s in stages[stage_idx + 1:]
                    if s.enabled
                )
                if not needed_later:
                    self.unload_model(stage.model_key)

            total_time = time.time() - start_time
            print(f"\n✓ Пайплайн завершён за {total_time:.1f}с")

            # Убираем промежуточный 'mix'
            stems.pop("mix", None)

            return PipelineResult(
                success=True,
                stems=stems,
                total_time=total_time,
            )

        except Exception as e:
            import traceback
            return PipelineResult(
                success=False,
                error=f"{type(e).__name__}: {e}\n{traceback.format_exc()}",
                total_time=time.time() - start_time,
            )

    def get_available_models(self) -> list[dict]:
        """Возвращаем список доступных моделей (для UI)."""
        result = []
        for key, cfg in KNOWN_MODELS.items():
            ckpt_path = self.models_dir / cfg.ckpt_path.split("/")[-1]
            result.append({
                "key": key,
                "name": cfg.name,
                "description": cfg.description,
                "available": ckpt_path.exists(),
                "stems": cfg.stem_names,
            })
        return result
