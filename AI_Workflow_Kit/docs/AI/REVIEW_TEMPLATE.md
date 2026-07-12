# Шаблон проверки (Verification Template)

Verification Engineer (**Gemini 3.5 Flash**) заполняет эту структуру в `FEEDBACK.md` на каждый review.

Проверяемый шаг: смотри `STATE.yaml` → `current_step`  
Требования шага: `OPT_STEPS.md` + `OPTIMIZATION_PLAN_GROK.md` (тот же шаг)

---

### 1. Сборка и интеграция
- Собирается / тестируется ли проект после этих изменений? (Да/Нет/Не применимо)
- Не нарушают ли изменения протокол backend ↔ Swift, job params, UI bindings?
*Комментарий:* ...

### 2. Логика и соответствие плану
- Выполнены ли все требования **текущего** шага из `OPT_STEPS.md`?
- Нет ли самодеятельности (код из K(n+1) на шаге K(n), Post-OPT и т.п.)?
- Соблюдены ли `target_files` (нет правок «заодно» вне списка без нужды)?
*Комментарий:* ...

### 3. Оптимальность и безопасность
- Нет ли cold `auto_tune_batch` / 8s probe на hot Separate path?
- Нет ли регрессий memory (лишние полные reload модели, unbounded caches)?
- Preview: нет ли mega-JSON там, где шаг уже требует binary (если применимо)?
*Комментарий:* ...

### 4. (если changes_requested) Конкретный список правок
1. ...
2. ...

---

**ИТОГОВЫЙ СТАТУС:** [APPROVED] или [CHANGES_REQUESTED]
