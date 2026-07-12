# KirtanSplitter — OPT implementation plan (pointer)

> **Исполнение:** оркестрация через `AI_Workflow_Kit/docs/` —  
> **Grok = Orchestrator**, **Hy3/Hi3 = coder**, **Gemini 3.5 Flash = reviewer**.

## Source of truth

| Doc | Role |
|-----|------|
| [`OPTIMIZATION_PLAN_GROK.md`](OPTIMIZATION_PLAN_GROK.md) | Full design, hybrid CPU/GPU/NPU, sprints, success metrics |
| [`OPTIMIZATION_PLAN.md`](OPTIMIZATION_PLAN.md) | Claude plan — concrete pseudocode reference |
| [`AI_Workflow_Kit/docs/OPT_STEPS.md`](AI_Workflow_Kit/docs/OPT_STEPS.md) | Agent step cards **K0–K8** |
| [`AI_Workflow_Kit/docs/AI/STATE.yaml`](AI_Workflow_Kit/docs/AI/STATE.yaml) | **What to do right now** |
| [`AI_Workflow_Kit/docs/AI/TEAM_CONTRACT.md`](AI_Workflow_Kit/docs/AI/TEAM_CONTRACT.md) | Roles & loop |

## Track

`OPT_PERF`: K0 → K1 → … → K8 → OPT_DONE

Do not implement Post-OPT until OPT_DONE.

## Human loop

1. Open `STATE.yaml` — see `next_actor`
2. **Before Hy3 on a new step:** ensure pre-checkpoint  
   `./script/opt_checkpoint.sh pre K0` (tag `opt/pre-K0` + push)
3. If `implementation` → run **Hy3** with: implement current step
4. If `verification` → run **Gemini 3.5 Flash** with: review per VERIFICATION_ENGINEER.md
5. If `orchestrator` → run **Grok** with: твоя очередь / advance  
   (on approve: `post Kn` + open next + `pre` next)
6. Rollback if needed: `./script/opt_checkpoint.sh rollback pre K1`  
   or `git reset --hard opt/pre-K1`  
   See `AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md`
