# DECISIONS — Orchestrator log

Orchestrator (Grok) пишет сюда решения при deadlock (`attempts >= 3`), scope cuts, or track policy changes.

---

## 2026-07-12 — Bootstrap OPT_PERF

- Ported Mandala `AI_Workflow_Kit` mechanics to KirtanSplitter.
- Roles: Grok orchestrator, Hy3 coder, Gemini 3.5 Flash reviewer.
- Scope plan: `OPTIMIZATION_PLAN_GROK.md` v3 (merged Claude feedback).
- Policy: no cold `auto_tune_batch` on Separate; no `.metallib` precompile.
- First step: **K0** baseline docs only.

## 2026-07-12 — Git checkpoints mandatory

- **Before every OPT step:** commit + annotated tag `opt/pre-Kn` + push to GitHub.
- **After every approved step:** commit + tag `opt/Kn-done` + push.
- Script: `script/opt_checkpoint.sh`
- Docs: `AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md`
- Rollback: `./script/opt_checkpoint.sh rollback pre Kn` or `git reset --hard opt/pre-Kn`
- Hy3 must refuse to code if `opt/pre-Kn` missing.

## 2026-07-12 — OPT_PERF closed

- K0–K8 all Gemini-approved; post tags `opt/K0-done` … `opt/K8-done` on GitHub.
- K7 had one CHANGES_REQUESTED cycle (STATE handoff only), then approved.
- Track set to `OPT_DONE`, `next_actor: human`.
- Post-OPT backlog remains optional (CoreML ONNX/ANE, colormap LUT, metal waveform).

