# KirtanSplitter — План оптимизации

> Документ подготовлен на основе полного анализа кодовой базы: Python-бэкенд (14 файлов), Swift-фронтенд (30+ файлов), конфигурации моделей, скрипты сборки и IPC-протокол.

---

## Содержание

1. [Производительность — Ускорение инференса моделей](#1-производительность--ускорение-инференса-моделей)
2. [Дизайн — Эстетика и минимализм интерфейса](#2-дизайн--эстетика-и-минимализм-интерфейса)
3. [Визуализация — Скорость и качество отображения аудио](#3-визуализация--скорость-и-качество-отображения-аудио)

---

## Текущая архитектура (краткое резюме)

```
┌─────────────────────────────────┐     JSON-RPC (TCP :51273)     ┌──────────────────────────────┐
│         Swift Frontend          │ ◄──────────────────────────► │        Python Backend         │
│                                 │                               │                              │
│  SwiftUI + Metal spectrogram    │    stdio / TCP JSON-lines     │  mlx-audio-separator v0.1.5  │
│  AVAudioEngine (playback)       │                               │  MLX → Metal GPU inference   │
│  No local DSP / FFT             │                               │  numpy FFT (spectrogram)     │
│  Cache: in-memory, unbounded    │                               │  ffmpeg (format conversion)  │
└─────────────────────────────────┘                               └──────────────────────────────┘
```

**Модели:** BS-RoFormer (639–699 MB), MelBand RoFormer, MDX23C, ONNX (Drums)
**Инференс:** MLX / Metal GPU, batch_size=1, `MLX_USE_FAST_SDP=1`
**IPC:** JSON-lines по TCP (продакшн) или stdio-пайпы

---

## 1. Производительность — Ускорение инференса моделей

### 1.1 Включить экспериментальные оптимизации MLX *(высокий приоритет, быстрый эффект)*

**Проблема:** В [engine.py:222-226](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/backend/kirtan_backend/engine.py#L222-L226) все 5 экспериментальных флагов жёстко выключены:

```python
"experimental_roformer_fast_norm": False,
"experimental_roformer_grouped_band_split": False,
"experimental_roformer_grouped_mask_estimator": False,
"experimental_roformer_fused_overlap_add": False,
"experimental_roformer_compile_fullgraph": False,
```

**План:**

| Флаг | Что делает | Ожидаемый эффект |
|------|-----------|------------------|
| `fast_norm` | Упрощённая нормализация (RMSNorm вместо LayerNorm) | 5–10% ускорение на каждом слое трансформера |
| `grouped_band_split` | Группировка полос частот при разбиении | Снижение числа операций в BandSplit модуле |
| `grouped_mask_estimator` | Группировка при оценке масок | Ускорение MaskEstimator (depth=2) |
| `fused_overlap_add` | Объединение overlap-add в один kernel | Меньше Metal dispatch вызовов, меньше синхронизаций |
| `compile_fullgraph` | Компиляция полного графа вычислений MLX | Наибольший потенциал: JIT-fusion всех ops |

**Действия:**
1. Поочерёдно включить каждый флаг и прогнать бенчмарк (`script/benchmark_models.py`)
2. Измерить деградацию качества (SDR) по каждому флагу
3. Включить флаги, не ухудшающие SDR, по умолчанию
4. Добавить UI-переключатели в Settings для тонкой настройки пользователем
5. Вынести текущие значения из хардкода в конфиг `SeparationJob`

---

### 1.2 Кэширование загруженной модели между запусками *(высокий приоритет)*

**Проблема:** В [engine.py:260](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/backend/kirtan_backend/engine.py#L260) объект `Separator()` создаётся **заново при каждом запросе на разделение**. Загрузка модели 639–699 MB из .safetensors + инициализация Metal pipeline занимает 3–8 секунд.

**План:**
1. Ввести `_cached_separator: Optional[Separator]` и `_cached_model_filename: str` в `MlxSeparatorEngine`
2. При вызове `separate()`: если `job.model == _cached_model_filename`, переиспользовать `_cached_separator`
3. Сбрасывать кэш только при смене модели или при ошибке OOM
4. Добавить в рантайм-статистику поле `model_hot: bool` для индикации в UI

```python
# Pseudo-diff для engine.py
class MlxSeparatorEngine:
    def __init__(self):
        ...
        self._cached_separator = None
        self._cached_model_filename = None

    def _get_or_load_separator(self, job):
        if self._cached_separator and self._cached_model_filename == job.model:
            return self._cached_separator
        separator = Separator(...)
        self._load_model(separator, job.model)
        self._cached_separator = separator
        self._cached_model_filename = job.model
        return separator
```

**Ожидаемый эффект:** Повторные запуски той же модели ускоряются на 3–8 секунд (пропуск загрузки).

---

### 1.3 Тюнинг Metal-аллокатора MLX *(средний приоритет)*

**Проблема:** Бэкенд не вызывает `mx.metal.set_memory_limit()` и `mx.metal.set_cache_limit()`. На машинах с ≥32 GB памяти MLX может использовать больше GPU-памяти для ускорения.

**План:**
1. Определять доступную GPU-память через `mx.metal.get_active_memory()` / `mx.metal.get_peak_memory()`
2. Устанавливать `memory_limit` = 80% от общей unified memory
3. Устанавливать `cache_limit` = размер модели × 2 (для хранения весов + промежуточных тензоров)
4. Добавить env-переменные `KIRTAN_MLX_MEMORY_LIMIT_GB` и `KIRTAN_MLX_CACHE_LIMIT_GB` для ручной настройки

```python
import mlx.core as mx

total_ram = os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')
mx.metal.set_memory_limit(int(total_ram * 0.8))
mx.metal.set_cache_limit(int(1.5 * 1024**3))  # 1.5 GB
```

---

### 1.4 Увеличение MDXC batch_size *(средний приоритет)*

**Проблема:** Дефолтный `mdxc_batch_size = 1` ([jobs.py:24](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/backend/kirtan_backend/jobs.py#L24)). Пресет Heavy использует 2, что говорит о том, что б**о**льшие значения работоспособны.

**План:**
1. Измерить производительность при batch_size = 1, 2, 4 на моделях BS-RoFormer
2. На машинах с ≥32 GB unified memory установить дефолт = 2 или 4
3. Добавить автоматическое определение оптимального batch_size на основе доступной GPU-памяти

---

### 1.5 Консолидация вызовов ffprobe *(низкий приоритет, быстрая победа)*

**Проблема:** В [engine.py:397-403](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/backend/kirtan_backend/engine.py#L397-L403) метод `_source_audio_format()` вызывает `ffprobe` **4 раза подряд** (channels, sample_rate, bit_depth, codec_name).

**План:** Заменить 4 вызова одним:

```python
def _source_audio_format(self, path: str) -> dict:
    cmd = [
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_streams", "-select_streams", "a:0", path
    ]
    data = json.loads(subprocess.check_output(cmd))
    stream = data["streams"][0]
    return {
        "channels": int(stream.get("channels", 2)),
        "sample_rate": int(stream.get("sample_rate", 44100)),
        "bit_depth": int(stream.get("bits_per_raw_sample", 16)),
        "codec": stream.get("codec_name", "pcm_s16le"),
    }
```

**Эффект:** Экономия ~300 мс на каждом запуске разделения (3 лишних subprocess spawn).

---

### 1.6 Автоочистка исходных .ckpt файлов *(низкий приоритет)*

**Проблема:** После конвертации `.ckpt` → `.safetensors` исходный файл не удаляется автоматически. Каждая модель занимает ~1.3 GB вместо ~650 MB.

**План:**
1. После успешной конвертации предлагать пользователю удалить `.ckpt`
2. Добавить кнопку «Clean source checkpoints» в настройки (аналог существующего `delete_model_group_source`)
3. При первом запуске после конвертации показывать уведомление с размером освобождаемого места

---

### 1.7 Гибридный CPU + GPU + NPU (ANE) — перспектива

**Текущее состояние:**
- **GPU (Metal):** Полностью используется через MLX для RoFormer моделей ✅
- **CPU:** Используется для FFT-анализа (numpy), ffmpeg конвертации ✅
- **NPU (Apple Neural Engine):** Не используется ❌

**Анализ возможности ANE:**
- ANE доступен через CoreML. Для его использования нужна конвертация модели в `.mlpackage` формат
- BS-RoFormer содержит **custom attention с Rotary Position Embeddings** — это плохо поддерживается CoreML/ANE
- Динамические размеры тензоров (зависят от длительности аудио) также несовместимы с ANE
- `mlx-audio-separator` библиотека не поддерживает CoreML экспорт

**Вердикт:** Полноценный ANE-инференс для RoFormer **нереалистичен** на текущем этапе. Рекомендуемая стратегия:

| Компонент | Процессор | Обоснование |
|-----------|-----------|-------------|
| RoFormer инференс | Metal GPU (MLX) | Оптимальный путь для transformer-моделей |
| FFT / спектрограмма | CPU → **GPU (Metal Compute)** | Перенести с numpy на Metal compute shader |
| Пиковый анализ волны | CPU → **Accelerate/vDSP** | Нативное SIMD-ускорение Apple |
| Audio decode (ffmpeg) | CPU | Единственный доступный путь |
| ONNX Drum модель | CoreML (GPU + ANE) | Уже частично поддерживается |

---

## 2. Дизайн — Эстетика и минимализм интерфейса

### 2.1 Централизованная система дизайн-токенов *(высокий приоритет)*

**Проблема:** Цвета, отступы, шрифты разбросаны хардкодом по 11+ файлам Views. Нет единого источника истины.

**Примеры хардкода:**
- `Color(red: 0.015, green: 0.018, blue: 0.026)` — встречается в 3 файлах
- `Color(red: 0.18, green: 0.55, blue: 1.0)` — waveform blue, дублируется
- Padding: 8, 9, 10, 12, 14, 16, 18, 20, 22px — без системы

**План:** Создать файл `Sources/KirtanSplitterApp/Models/DesignTokens.swift`:

```swift
enum KSTheme {
    // MARK: — Backgrounds
    static let canvasBackground = Color(red: 0.015, green: 0.018, blue: 0.026)
    static let panelBackground  = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let surfaceBackground = Color(red: 0.08, green: 0.10, blue: 0.14)
    
    // MARK: — Accents
    static let accent           = Color.orange
    static let waveformBlue     = Color(red: 0.18, green: 0.55, blue: 1.0)
    static let playheadAmber    = Color(red: 1.0, green: 0.74, blue: 0.18)
    static let clippingRed      = Color(red: 1.0, green: 0.22, blue: 0.20)
    static let decibelPink      = Color(red: 1.0, green: 0.18, blue: 0.32)
    
    // MARK: — Spacing
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 20
    static let spacingXXL: CGFloat = 24
    
    // MARK: — Corner Radii
    static let radiusSM: CGFloat = 6
    static let radiusMD: CGFloat = 10
    static let radiusLG: CGFloat = 14
    
    // MARK: — Shadows & Glows
    static let glowRadius: CGFloat = 12
    static let glowOpacity: Double = 0.35
}
```

Затем заменить все хардкоды на ссылки: `KSTheme.canvasBackground`, `KSTheme.spacingMD`, и т.д.

---

### 2.2 Glassmorphism для аудио-превью области *(средний приоритет)*

**Проблема:** Нижняя панель с волновой формой и спектрограммой использует плоский `Color(red:)` фон, в то время как остальные панели используют `.thinMaterial` / `.regularMaterial`.

**План:**
1. Обернуть аудио-канвас в `.background(.ultraThinMaterial)` с `opacity(0.6)`
2. Добавить тонкий border `1px` с `Color.white.opacity(0.06)` для стеклянного эффекта
3. Скруглить углы верхнего края панели для визуального «отрыва» от контента

```swift
// AudioPreviewPane.swift — body wrapper
.background {
    RoundedRectangle(cornerRadius: KSTheme.radiusLG)
        .fill(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: KSTheme.radiusLG)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
}
```

---

### 2.3 Микро-анимации и hover-эффекты *(средний приоритет)*

**Проблема:** Только кнопка настроек (`SettingsSidebarToggleButtonStyle`) имеет анимации (scale + glow). Остальной UI статичен.

**План:**
1. **Stem rows:** Добавить hover-подсветку (`onHover` → фоновая анимация opacity 0→0.06)
2. **Widget panels:** Плавная анимация раскрытия/сворачивания контента (`.animation(.spring(response: 0.3))`)
3. **Model dropdown rows:** Анимация чекбокса (scale bounce при toggle)
4. **Preview mode tabs (Wave/Spectral):** Animated underline indicator, а не мгновенное переключение
5. **Loading states:** Shimmer-эффект для загружающихся спектрограмм вместо статичного ProgressView

---

### 2.4 Типографика *(низкий приоритет)*

**Проблема:** Используются стандартные системные шрифты SF Pro. Для профессионального аудио-инструмента стоит рассмотреть более «инженерный» стиль.

**План:**
1. Заменить числовые значения (dB, Hz, время) на `SF Mono` для табулярного выравнивания (уже частично сделано через `.monospacedDigit()`, расширить)
2. Рассмотреть `SF Pro Rounded` для заголовков панелей — более мягкий и современный вид
3. Увеличить контраст label-ов: `.primary` для значений, `.tertiary` для единиц измерения

---

### 2.5 Устранение дублирования UI-компонентов *(средний приоритет)*

**Проблема:** ~400 строк кода дублируется между `AudioPreviewPane` и `ComparisonPane` (весь код рисования волны, сетки, осей, плейхеда). Также дублируются: stem icon/color маппинг, volume slider.

**План:**
1. Извлечь общие функции рисования в `AudioDrawingUtilities.swift`:
   - `drawWaveform(context:analysis:viewport:rect:layerSettings:)`
   - `drawGrid(context:duration:viewport:rect:)`
   - `drawAxisLabels(context:duration:viewport:rect:)`
   - `drawPlayhead(context:currentTime:duration:viewport:rect:)`
   - `samplePeaks(peaks:viewport:count:)`
2. Извлечь `StemAppearance.swift` с единой таблицей stem → (icon, color)
3. Извлечь `VolumeSliderWidget` в отдельный переиспользуемый View

---

## 3. Визуализация — Скорость и качество отображения аудио

### 3.1 Бинарный протокол для передачи спектрограмм *(критический приоритет)*

**Проблема:** Спектрограмма (8192 × 224 = 1,835,008 значений `Double`) передаётся как JSON-текст. Это:
- **~25–50 MB** JSON на одну спектрограмму (каждый double ~14-17 символов + разделители)
- **~7.3 MB** в бинарном Float32 формате
- JSON-парсинг 50 MB текста занимает **0.5–2 секунды** только на десериализацию
- Итого: анализ 5-минутного трека может ждать 2-4 сек только на передачу данных

**План:** Гибридный JSON + бинарный протокол:

#### Бэкенд (Python):
```python
# audio_analysis.py — новый метод
def analyze_audio_binary(path, waveform_points, spec_columns, spec_bins):
    analysis = analyze_audio(path, waveform_points, spec_columns, spec_bins)
    
    # Сохранить бинарные данные во временный файл
    bin_path = tempfile.mktemp(suffix=".ksbin")
    with open(bin_path, "wb") as f:
        # Header: version(1B) + waveform_count(4B) + spec_columns(4B) + spec_bins(4B)
        f.write(struct.pack("<BII I", 1, waveform_points, spec_columns, spec_bins))
        # Waveform peaks as float32
        np.array(analysis["waveformPeaks"], dtype=np.float32).tofile(f)
        # Spectrogram as float32
        np.array(analysis["spectrogram"]["values"], dtype=np.float32).tofile(f)
    
    # JSON содержит только metadata + путь к бинарному файлу
    result = {k: v for k, v in analysis.items() if k not in ("waveformPeaks", "spectrogram")}
    result["binaryPayloadPath"] = bin_path
    return result
```

#### Фронтенд (Swift):
```swift
// BackendClient.swift — новый метод
func analyzeAudioFast(url: URL) async throws -> AudioAnalysis {
    let meta = try await sendRequest(method: "analyze_audio", params: [...])
    let metaObj = try decodeObject(AudioAnalysisMeta.self, from: meta)
    
    // Чтение бинарного payload из файла (memory-mapped)
    let data = try Data(contentsOf: URL(fileURLWithPath: metaObj.binaryPayloadPath),
                        options: .mappedIfSafe)
    let peaks = data.withUnsafeBytes { /* parse float32 array */ }
    let specValues = data.withUnsafeBytes { /* parse float32 array */ }
    
    try? FileManager.default.removeItem(atPath: metaObj.binaryPayloadPath)
    return AudioAnalysis(meta: metaObj, peaks: peaks, spectrogram: specValues)
}
```

**Ожидаемый эффект:**
- Размер передачи: **50 MB → 7.3 MB** (7× меньше)
- Время парсинга: **1–2 сек → <50 мс** (mmap + pointer cast, без десериализации)
- Общая латентность анализа: **3–5 сек → 1–2 сек**

---

### 3.2 Перенос FFT-вычислений на GPU (Metal Compute Shader) *(высокий приоритет)*

**Проблема:** Спектрограмма вычисляется на CPU через `numpy.fft.rfft` ([audio_analysis.py:172-233](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/backend/kirtan_backend/audio_analysis.py#L172-L233)). Для 5-минутного трека при 44100 Hz это ~13.2M семплов, обрабатываемых чанками по 64 MB.

**План (вариант А — Swift-side Metal Compute):**
Перенести FFT-вычисления **в Swift** через Accelerate/vDSP + Metal Compute:

1. Бэкенд отдаёт только raw PCM float32 данные (через бинарный протокол из п.3.1)
2. Swift выполняет FFT через `vDSP.FFT` (Accelerate framework) — это SIMD-оптимизировано для Apple Silicon
3. Mel-масштабирование и логарифмирование — через Metal compute shader
4. Результат сразу загружается как текстура, **без промежуточных CPU-массивов**

```swift
import Accelerate

func computeSpectrogram(pcm: UnsafeBufferPointer<Float>, 
                         fftSize: Int, hopLength: Int, bins: Int) -> MTLTexture {
    let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(fftSize))),
                        radix: .radix2, ofType: DSPSplitComplex.self)!
    // ... windowing, FFT, magnitude, mel binning ...
    // Upload directly to MTLTexture
}
```

**План (вариант Б — Python-side MLX FFT, менее предпочтителен):**
Заменить `numpy.fft.rfft` на `mx.fft.rfft` для GPU-ускоренного FFT в бэкенде.

**Ожидаемый эффект:** 
- vDSP FFT на M1/M2/M3: **5–20× быстрее** чем numpy на CPU
- Устранение передачи 7.3 MB спектрограммы (вычисляется локально)
- Общая латентность: **1–2 сек → 100–300 мс** для типичного 5-мин трека

---

### 3.3 Прогрессивная (инкрементальная) загрузка визуализации *(высокий приоритет)*

**Проблема:** Сейчас анализ — это «всё или ничего»: пользователь видит пустой экран пока полный анализ не завершится. iZotope RX и SpectraLayers показывают контент мгновенно потому что используют прогрессивную загрузку.

**План:**

#### Фаза 1 — Мгновенная волновая форма (~50 мс):
1. Бэкенд сначала отдаёт low-res waveform (512 пиков) — это занимает <50 мс
2. Swift сразу рендерит грубую волновую форму
3. Пользователь уже видит контент и может навигировать

#### Фаза 2 — Быстрая волновая форма (~200 мс):
1. Бэкенд параллельно вычисляет full-res waveform (8192 пиков)
2. Swift обновляет отображение — плавный morph от low-res к high-res

#### Фаза 3 — Спектрограмма (~500-1000 мс):
1. Бэкенд вычисляет спектрограмму чанками (или Swift считает локально через vDSP)
2. По мере готовности каждого чанка текстура обновляется полосами слева направо
3. Пользователь видит «заливку» спектрограммы — ощущение мгновенной реакции

**Реализация протокола:**
```json
// Фаза 1 — мгновенный ответ
{"type": "response", "id": "req_1", "result": {
    "phase": "waveform_preview",
    "waveformPeaks": [... 512 значений ...],
    "duration": 312.5, "channels": 2, ...
}}

// Фаза 2 — полная волна
{"type": "progress", "id": "req_1", "result": {
    "phase": "waveform_full",
    "binaryPayloadPath": "/tmp/ks_wave_full.bin"
}}

// Фаза 3 — спектрограмма (чанками)
{"type": "progress", "id": "req_1", "result": {
    "phase": "spectrogram_chunk",
    "chunkIndex": 0, "totalChunks": 8,
    "binaryPayloadPath": "/tmp/ks_spec_chunk0.bin"
}}
```

---

### 3.4 Устранение CPU-транспозиции текстуры *(средний приоритет)*

**Проблема:** В [MetalSpectrogramTexturePayload.swift:13-21](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/Sources/KirtanSplitterApp/Models/MetalSpectrogramTexturePayload.swift#L13-L21) при каждом обновлении текстуры происходит O(columns × bins) CPU-транспозиция из column-major в row-major порядок.

**План (2 варианта):**

**Вариант А (быстрый):** Бэкенд отдаёт данные сразу в row-major порядке. Одна строчка в `audio_analysis.py`:
```python
# Вместо column-major хранения
values = spectrogram.T.flatten().tolist()  # → row-major
```

**Вариант Б (лучше):** Транспозицию делает Metal compute shader за 1 dispatch:
```metal
kernel void transpose(
    device const float* src [[buffer(0)]],
    device float* dst [[buffer(1)]],
    constant uint2& dims [[buffer(2)]],  // (columns, bins)
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x < dims.x && gid.y < dims.y) {
        dst[gid.y * dims.x + gid.x] = src[gid.x * dims.y + gid.y];
    }
}
```

**Эффект:** Экономия ~5–15 мс на каждом обновлении текстуры (8192×224 = 1.8M элементов).

---

### 3.5 Улучшенный колормап спектрограммы *(средний приоритет)*

**Проблема:** Текущий колормап в [MetalSpectrogramShader.swift:44-67](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/Sources/KirtanSplitterApp/Models/MetalSpectrogramShader.swift#L44-L67) — это простой 3-сегментный градиент (тёмно-синий → маджента → амбер). Профессиональные инструменты (iZotope RX, SpectraLayers) используют перцептуально-равномерные колормапы.

**План:**
1. Реализовать набор колормапов: `Magma`, `Inferno`, `Viridis` (научно обоснованные, perceptually uniform)
2. Добавить переключатель колормапа в UI настроек спектрограммы
3. Реализовать как LUT-текстуру (256-entry 1D texture) — одна операция `texture.sample()` в шейдере

```metal
// Вместо процедурного колормапа — LUT
fragment half4 spectrogramFragment(VertexOut in [[stage_in]],
                                    texture2d<float> data [[texture(0)]],
                                    texture1d<half> colormap [[texture(1)]],
                                    constant Uniforms& u [[buffer(0)]]) {
    float value = data.sample(sampler, uv).r;
    value = pow(clamp(value * u.gain, 0.0, 1.0), 0.82);
    return colormap.sample(cmapSampler, value);
}
```

4. Добавить контрол `gain` (уже есть как параметр Uniforms, но нет UI-слайдера)

---

### 3.6 Улучшение кэша анализа *(средний приоритет)*

**Проблема:** Текущий [AudioPreviewAnalysisCache.swift](file:///Users/pavan/Documents/AI%20Projects/KirtanSplitter/Sources/KirtanSplitterApp/Models/AudioPreviewAnalysisCache.swift):
- Неограниченный рост (каждый анализ ~14 MB в heap)
- Нет LRU-вытеснения
- Нет персистентности (теряется при перезапуске)
- Сбрасывается при загрузке нового source-файла

**План:**
1. Ограничить кэш: максимум 20 записей или 256 MB
2. LRU-вытеснение: добавить `lastAccessDate` к каждой записи
3. Disk-кэш: сохранять бинарные данные в `~/Library/Caches/KirtanSplitter/previews/`
4. Хеш-ключ: использовать SHA256(file_path + file_size + modification_date) вместо просто path
5. При запуске приложения: загружать metadata из disk-кэша, lazy-load данных при обращении

---

### 3.7 Рендеринг волновой формы на Metal *(низкий приоритет, перспектива)*

**Проблема:** Волновая форма рисуется через SwiftUI `Canvas` (Core Graphics, CPU). При высоком зуме (8192+ точек видимы) это может вызывать фреймдропы.

**Текущее состояние:** Производительность приемлема благодаря динамическому ограничению `drawPoints = min(max(96, Int(width * 1.25)), visibleSamples * 2)` — максимум ~4800 точек на перерисовку.

**План (если появятся проблемы с fps):**
1. Перенести рисование волны в Metal vertex/fragment shader
2. Пики хранятся в `MTLBuffer`, обновляются только при смене файла
3. Viewport (zoom/pan) передаётся через uniforms — перерисовка без пересчёта геометрии
4. Заливка envelope — через instanced triangles strip
5. Линии — через line primitives с аппаратным anti-aliasing

---

## Сводная таблица приоритетов

| # | Категория | Задача | Приоритет | Сложность | Ожидаемый эффект |
|---|-----------|--------|-----------|-----------|------------------|
| 1.1 | Перф | Включить эксп. оптимизации MLX | 🔴 Высокий | Низкая | 10–30% ускорение инференса |
| 1.2 | Перф | Кэширование Separator | 🔴 Высокий | Средняя | −3–8 сек на повторных запусках |
| 1.3 | Перф | Тюнинг Metal-аллокатора | 🟡 Средний | Низкая | 5–15% на больших моделях |
| 1.4 | Перф | Увеличение MDXC batch_size | 🟡 Средний | Низкая | 10–20% при batch>1 |
| 1.5 | Перф | Консолидация ffprobe | 🟢 Низкий | Низкая | −300 мс на запуск |
| 1.6 | Перф | Автоочистка .ckpt | 🟢 Низкий | Низкая | −650 MB диска на модель |
| 3.1 | Визуал | Бинарный протокол | 🔴 Критический | Средняя | 7× меньше данных, −1.5 сек |
| 3.2 | Визуал | FFT на vDSP/Metal | 🔴 Высокий | Высокая | 5–20× ускорение спектрограммы |
| 3.3 | Визуал | Прогрессивная загрузка | 🔴 Высокий | Высокая | Субъективно «мгновенный» отклик |
| 3.4 | Визуал | Устранение CPU-транспозиции | 🟡 Средний | Низкая | −5–15 мс на обновление |
| 3.5 | Визуал | Улучшенные колормапы | 🟡 Средний | Средняя | Профессиональный вид |
| 3.6 | Визуал | Улучшение кэша | 🟡 Средний | Средняя | Персистентность + LRU |
| 3.7 | Визуал | Metal-рендер волны | 🟢 Низкий | Высокая | Запас на будущее |
| 2.1 | Дизайн | Дизайн-токены | 🔴 Высокий | Средняя | Консистентность, поддерживаемость |
| 2.2 | Дизайн | Glassmorphism превью | 🟡 Средний | Низкая | Визуальная целостность |
| 2.3 | Дизайн | Микро-анимации | 🟡 Средний | Средняя | Ощущение «живого» UI |
| 2.4 | Дизайн | Типографика | 🟢 Низкий | Низкая | Профессиональный стиль |
| 2.5 | Дизайн | Устранение дублирования | 🟡 Средний | Средняя | −400 строк, поддерживаемость |

---

## Рекомендуемый порядок реализации

### Спринт 1 — Быстрые победы (1–2 дня)
- [1.1] Включить экспериментальные оптимизации + бенчмарк
- [1.5] Консолидация ffprobe
- [3.4] Устранение CPU-транспозиции (вариант А — row-major в бэкенде)

### Спринт 2 — Критический прирост скорости (3–5 дней)
- [3.1] Бинарный протокол для спектрограмм
- [1.2] Кэширование загруженной модели
- [2.1] Дизайн-токены

### Спринт 3 — Профессиональная визуализация (5–7 дней)
- [3.2] FFT на vDSP (Swift-side) — перенос вычислений
- [3.3] Прогрессивная загрузка визуализации
- [2.5] Устранение дублирования кода рисования

### Спринт 4 — Полировка (3–5 дней)
- [1.3] Тюнинг Metal-аллокатора MLX
- [1.4] Увеличение MDXC batch_size
- [2.2] Glassmorphism
- [2.3] Микро-анимации
- [3.5] Улучшенные колормапы
- [3.6] Улучшение кэша

### Перспектива
- [3.7] Metal-рендер волновой формы
- [1.6] Автоочистка .ckpt
- [2.4] Кастомная типографика
- [1.7] Исследование ANE для ONNX-моделей
