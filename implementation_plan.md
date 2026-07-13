# AuraSplitter — implementation plan (pointer)

> **Исполнение:** `AI_Workflow_Kit/docs/` —  
> **Grok = Orchestrator**, **Hy3/Hi3 = coder**, **Gemini 3.5 Flash = reviewer**.  
> **Extra:** after Gemini approve → **build app + visual accept** before post-tag.

## Source of truth

| Doc | Role |
|-----|------|
| [`AI_Workflow_Kit/docs/DESIGN_STEPS.md`](AI_Workflow_Kit/docs/DESIGN_STEPS.md) | Agent step cards **D0–D6** (active) |
| [`AI_Workflow_Kit/docs/AI/STATE.yaml`](AI_Workflow_Kit/docs/AI/STATE.yaml) | **What to do right now** |
| [`AI_Workflow_Kit/docs/AI/TEAM_CONTRACT.md`](AI_Workflow_Kit/docs/AI/TEAM_CONTRACT.md) | Roles & loop |
| [`AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md`](AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md) | pre/post tags + push |
| [`OPTIMIZATION_PLAN_GROK.md`](OPTIMIZATION_PLAN_GROK.md) | Closed OPT_PERF design (reference) |

## Active track

`DESIGN_V2`: D0 → D1 → … → D6 → DESIGN_DONE  
Display name: **AuraSplitter**

## Human loop

1. Open `STATE.yaml` — see `next_actor` and `current_step`
2. **Before Hy3 on a new step:**  
   `./script/opt_checkpoint.sh pre D0` (tag `design/pre-D0` + push)
3. If `implementation` → **Hy3**: implement current step only (`target_files`)
4. If `verification` → **Gemini 3.5 Flash**: review → `FEEDBACK.md`
5. If Gemini APPROVED → **Grok**: build app, visual checklist
6. Visual PASS → `./script/opt_checkpoint.sh post Dn "…"` + open next step + `pre` next  
   Visual FAIL → `fix_prompt` in STATE → Hy3 retry (same step)

## Closed track

`OPT_PERF` K0–K8 complete (`opt/*-done` tags).
