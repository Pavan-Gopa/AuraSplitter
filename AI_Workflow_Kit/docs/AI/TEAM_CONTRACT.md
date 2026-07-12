# AI Team Contract — KirtanSplitter

## Source of truth (priority)

1. `AI_Workflow_Kit/docs/AI/STATE.yaml` — **что делать прямо сейчас**
2. `AI_Workflow_Kit/docs/OPT_STEPS.md` — карточка шага
3. `OPTIMIZATION_PLAN_GROK.md` — полный OPT design / budgets
4. `OPTIMIZATION_PLAN.md` — Claude-детали / псевдокод (референс)
5. `AI_Workflow_Kit/docs/PROJECT_CONTEXT.md` — контекст репо

## Roles

| Role | Model | Writes code? | Updates |
|------|-------|--------------|---------|
| **Orchestrator** | Grok | only if attempts ≥ 3 | `STATE.yaml`, occasionally `DECISIONS.md` |
| **Implementation Engineer** | **Hy3 / Hi3** | **yes** | code in `target_files`, then `implementation.status` |
| **Verification Engineer** | **Gemini 3.5 Flash** | no | `FEEDBACK.md`, `review.status` |

No role redesigns architecture unless Orchestrator explicitly allows.

## Workflow (shared filesystem)

```
Orchestrator: git checkpoint PRE step (commit + tag opt/pre-Kn + push)
        ↓
Orchestrator prepares STATE (step + target_files)
        ↓
Human → Hy3: implement
        ↓
Hy3 codes → verify → implementation.status = waiting_review
        ↓
Human → Gemini: review
        ↓
Gemini → FEEDBACK.md → review.status = approved | changes_requested
        ↓
Human → Orchestrator: advance or retry
        ↓
If approved: git checkpoint POST step (commit + tag opt/Kn-done + push)
        ↓
PRE next step → (loop)
```

1. Orchestrator (or human) runs **pre-step git checkpoint** for `Kn` — see `GIT_CHECKPOINTS.md`.
2. Orchestrator готовит `STATE.yaml` для шага.
3. Человек даёт команду **Hy3**.
4. Hy3 читает STATE, пишет код **только** в `target_files`, прогоняет verify, ставит `implementation.status = waiting_review`, `next_actor: verification`.
5. Человек даёт команду **Gemini 3.5 Flash**.
6. Gemini ревьюит по `REVIEW_TEMPLATE.md`, пишет `FEEDBACK.md`, ставит `review.status`, `next_actor: orchestrator`.
7. Человек даёт команду **Orchestrator (Grok)**.
8. Orchestrator: on **approved** → **post-step checkpoint** → next step + **pre** for next; on **changes_requested** → retry with `attempts++` (no post tag).

## Hard rules

- Keep the project **buildable/testable** every step (`pytest` and/or `swift build` / `swift test` for touched stack).
- One OPT step at a time (K0…K8).
- **Git checkpoint before every step and after every approved step** (commit + annotated tag + push to GitHub). Details: `AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md`. Script: `./script/opt_checkpoint.sh`.
- No Post-OPT (CoreML ONNX full runner, etc.) until OPT track accepted.
- **Never** enable cold `auto_tune_batch` on the hot Separate path (probe ~8s). Cache-hit only or offline calibrate.
- **No** `.metallib` precompile migration (low ROI).
- Communication between agents is **via files only** — human switches models.
- Do **not** force-update (`-f`) opt tags; preserve rollback points.
