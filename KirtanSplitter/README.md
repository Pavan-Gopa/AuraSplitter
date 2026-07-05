# KirtanSplitter

Нативное macOS приложение для разделения киртанов на stems.
Backend на **MLX** (Apple Silicon) — максимальная скорость через Metal GPU + Unified Memory.
Модели: **BSRoformer** (Band-Split RoFormer) — лучшее качество source separation на сегодня.

---

## Архитектура

```
KirtanSplitter/
├── KirtanSplitter/          # Swift/SwiftUI (нативный UI)
│   ├── ContentView.swift    # Главный экран
│   └── PythonBridge.swift   # IPC с Python backend
│
├── backend/                 # Python (MLX inference)
│   ├── bsroformer_mlx.py    # BSRoformer архитектура на MLX
│   ├── audio_inference.py   # STFT, чанковый инференс
│   ├── pipeline.py          # Оркестратор многоступенчатого разделения
│   └── server.py            # JSON-RPC сервер (stdin/stdout)
│
├── models/                  # Чекпоинты моделей (.npz после конвертации)
└── tools/
    └── convert_weights.py   # Конвертер PyTorch → MLX
```

### Поток данных

```
Swift UI
  │
  │  JSON over stdin/stdout (Process IPC)
  ▼
Python Server (server.py)
  │
  ▼
Pipeline Orchestrator (pipeline.py)
  │
  ├── Stage 1: BSRoformer [vocals / instrumental]
  │     ↓ Audio → STFT → MLX inference → iSTFT → WAV
  │
  ├── Stage 2: BSRoformer [lead_vocals / backing_vocals]
  │     ↓ (вход: vocals из Stage 1)
  │
  └── Stage 3: BSRoformer [drums / no_drums]
        ↓ (вход: instrumental из Stage 1)
```

### Почему MLX быстрее UVR5

| | UVR5 (стандарт) | KirtanSplitter |
|---|---|---|
| Бэкенд | PyTorch CPU / MPS | MLX (Metal) |
| Память | CPU RAM ↔ GPU VRAM копирование | Unified Memory (нет копирования) |
| STFT | CPU (librosa) | scipy + Metal |
| JIT | Нет | Автоматическая компиляция графа |
| Ожидаемый выигрыш | 1× | **2–4×** |

---

## Установка

### 1. Требования
- macOS 13+ (Ventura или новее)
- Apple Silicon (M1/M2/M3/M4) — для максимальной скорости
- Python 3.11+
- Xcode 15+

### 2. Python зависимости

```bash
# Устанавливаем через Homebrew Python (рекомендуется)
brew install python@3.11

pip3 install mlx soundfile scipy numpy resampy
pip3 install safetensors  # опционально, для лучшего формата весов

# Только для конвертации весов (не нужен для работы приложения):
pip3 install torch --index-url https://download.pytorch.org/whl/cpu
```

### 3. Скачиваем модели BSRoformer

Модели берём с HuggingFace. Самые полезные для киртана:

```bash
mkdir -p models
cd models

# Основная модель (вокал/инструменты) — SDR 12.97 dB
wget "https://huggingface.co/TRvlvr/model_repo/resolve/main/model_bs_roformer_ep_317_sdr_12.9755.ckpt"

# Барабаны (табла) — SDR 10.5 dB  
wget "https://huggingface.co/TRvlvr/model_repo/resolve/main/model_drums_bs_roformer_ep_17_sdr_10.5096.ckpt"

# Mel-Band версия (для бэк-вокала)
wget "https://huggingface.co/KimberleyJSN/melbandroformer/resolve/main/mel_band_roformer_vocals_ep_937_sdr_10.56.ckpt"
```

Все доступные модели: https://huggingface.co/TRvlvr/model_repo

### 4. Конвертируем веса в MLX формат

```bash
# Конвертация одного файла
python3 tools/convert_weights.py \
    --input models/model_bs_roformer_ep_317_sdr_12.9755.ckpt \
    --output models/model_bs_roformer_ep_317_sdr_12.9755.npz \
    --verify

# Пакетная конвертация всей папки
python3 tools/convert_weights.py --input models/ --output models/

# После конвертации torch больше не нужен
```

### 5. Тест backend из командной строки

```bash
cd backend
python3 server.py &

# Отправляем тестовый запрос
echo '{"id":"1","method":"ping","params":{}}' | python3 server.py
# → {"type": "response", "id": "1", "result": {"status": "ok", "backend": "mlx"}}

# Разделяем файл
echo '{
  "id":"2",
  "method":"separate",
  "params":{
    "input_path":"/path/to/kirtan.wav",
    "output_dir":"/tmp/stems",
    "preset":"kirtan"
  }
}' | python3 server.py
```

### 6. Сборка macOS приложения

```bash
open KirtanSplitter.xcodeproj
# В Xcode: Product → Build (⌘B)
# Или:
xcodebuild -project KirtanSplitter.xcodeproj -scheme KirtanSplitter -configuration Release build
```

---

## Пресеты разделения

### kirtan (рекомендуется)
```
Входной файл
    ↓ BSRoformer (vocals)
    ├── vocals.wav
    │     ↓ BSRoformer Mel (vocals)
    │     ├── lead_vocals.wav      ← основной вокал
    │     └── backing_vocals.wav   ← бэк-вокал, ааа-ааа
    │
    └── instrumental.wav
          ↓ BSRoformer (drums)
          ├── drums.wav            ← табла, пакхавадж
          └── no_drums.wav         ← гармониум, фисгармония, прочее
```

### quick
Только первая ступень: vocals + instrumental

### full
BSRoformer 6-stem (если есть модель): vocals, drums, bass, other, piano, guitar

---

## Кастомизация

### Добавить свою модель

В `pipeline.py`, в словарь `KNOWN_MODELS`:

```python
"my_model": ModelConfig(
    name="Моя модель",
    ckpt_path="models/my_model.npz",
    stem_names=["vocals", "music"],
    dim=512,        # из конфигурации модели
    depth=12,       # из конфигурации модели
    num_sources=2,
    description="Описание",
),
```

### Кастомный пайплайн

```python
from pipeline import PipelineStage, KirtanPipeline

my_pipeline = [
    PipelineStage(
        stage_name="Вокал",
        model_key="bs_roformer_vocals",
        input_stem="mix",
        output_stems=["vocals", "instrumental"],
    ),
    # Добавить ещё ступени...
]

pipeline = KirtanPipeline(models_dir="models", chunk_seconds=30.0)
result = pipeline.run(
    input_path="kirtan.wav",
    output_dir="output/",
    stages=my_pipeline,
    progress_cb=lambda stage, p: print(f"{stage}: {p:.0%}"),
)
```

---

## Оптимизация скорости

### chunk_seconds
Ключевой параметр. Больше чанк = меньше накладных расходов, но больше памяти.
- M1 8GB RAM: `chunk_seconds=20`
- M1 Pro 16GB: `chunk_seconds=30`
- M2 Max 32GB+: `chunk_seconds=60`

### Параллельная обработка ступеней 2 и 3
Ступени 2 (бэк-вокал) и 3 (табла) независимы — можно запускать параллельно.
На M2 Pro+ с достаточной памятью это даёт ~1.5× ускорение.
(TODO в следующей версии)

### Core ML (экспериментально)
Конвертация в Core ML для Neural Engine — максимальная скорость:
```bash
pip3 install coremltools
python3 tools/convert_to_coreml.py --input models/model.npz  # TODO
```
Ограничение: BSRoformer с динамическими размерами плохо конвертируется в ANE.
Требует фиксации chunk_size на этапе конвертации.

---

## Известные проблемы

1. **torch нужен для конвертации** — установите только для запуска `convert_weights.py`,
   после этого можно удалить (`pip uninstall torch`)
   
2. **Первый запуск медленнее** — MLX компилирует Metal шейдеры (~30 сек).
   Последующие запуски быстрее из кэша.

3. **MP3 входные файлы** — конвертируются через AVFoundation, небольшая потеря качества.
   Рекомендуется WAV или FLAC.

---

## Дорожная карта

- [ ] Core ML конвертер (Neural Engine)
- [ ] Параллельная обработка независимых ступеней  
- [ ] Waveform визуализация каждого stem в UI
- [ ] Пресет "Живой киртан" с деревербацией
- [ ] Пакетная обработка папки файлов
- [ ] Экспорт в Logic Pro / GarageBand
- [ ] Поддержка MIDI-синхронизации (align stems по BPM)
