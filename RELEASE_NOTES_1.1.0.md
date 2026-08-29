# AuraSplitter 1.1.0

## Исправлено

- **Обработка FLAC/аудио падала сразу после Start.** `mlx-audio-io` сверяет нативное расширение `_core.so` с хешем из dist-info RECORD. Подпись Developer ID (обязательная для Gatekeeper) меняет байты `.so`, из‑за этого появлялась ошибка `Native extension hash mismatch vs dist-info RECORD`. Релиз теперь переписывает RECORD-хеши после codesign, а backend в `.app` больше не блокирует загрузку подписанного расширения.

## Обновление

- Установите из приложения: **Settings → Check for Updates Now**, либо через меню AuraSplitter. Апдейтер скачает zip, проверит подпись и SHA-256 и заменит текущую версию.
- Либо откройте DMG и перетащите **AuraSplitter** в Applications.
