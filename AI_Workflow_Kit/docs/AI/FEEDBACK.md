# FEEDBACK — DESIGN_V2

## Track
**DESIGN_V2** — current step set in `STATE.yaml`.

## Template for Gemini 3.5 Flash

```markdown
## Step: Dn — <title>
## Verdict: APPROVED | CHANGES_REQUESTED

### Summary
…

### Checks
- [ ] Diff limited to STATE target_files (or justified)
- [ ] Requirements from DESIGN_STEPS.md met
- [ ] Verify commands run (pytest / swift build)
- [ ] No scope creep into later Dn

### Issues (if CHANGES_REQUESTED)
1. …

### Notes for orchestrator
…
```

## Status
Awaiting **D0** implementation (Hy3). No review yet.

OPT_PERF historical approvals: see git tags `opt/K0-done` … `opt/K8-done`.
