# Git checkpoints — OPT_PERF + DESIGN_V2

Перед **каждым** шагом и после **закрытия** шага обязателен git-коммит + tag + **push на GitHub**. Цель: всегда можно откатиться.

## Naming — OPT_PERF (closed)

| Moment | Tag | Commit message (пример) |
|--------|-----|-------------------------|
| **До** старта шага `Kn` | `opt/pre-Kn` | `chore(opt): checkpoint before Kn` |
| **После** approve `Kn` | `opt/Kn-done` | `feat(opt): Kn — <кратко>` |

## Naming — DESIGN_V2 (active)

| Moment | Tag | Commit message (пример) |
|--------|-----|-------------------------|
| **До** старта шага `Dn` | `design/pre-Dn` | `chore(design): checkpoint before Dn` |
| **После visual PASS** `Dn` | `design/Dn-done` | `feat(design): Dn — <кратко>` |

**DESIGN_V2 close rule:** Gemini APPROVED is not enough. Orchestrator must **build & visually accept** the app, then `post` + push.

Теги **не** перезаписывать (`-f` запрещён).

## Script

```bash
# OPT (legacy):
./script/opt_checkpoint.sh pre K0
./script/opt_checkpoint.sh post K0 "baseline PERF_BASELINE.md"

# DESIGN_V2:
./script/opt_checkpoint.sh pre D0
./script/opt_checkpoint.sh post D0 "AuraSplitter branding"

# Список:
./script/opt_checkpoint.sh list

# Откат (осторожно!):
./script/opt_checkpoint.sh rollback pre D0
./script/opt_checkpoint.sh rollback pre K1
```

`pre` / `post`:
1. `git status` — если есть изменения, `git add` + `commit`
2. `git tag` `opt/…` or `design/…`
3. `git push origin HEAD` + `git push origin <tag>`

## Who does what

| Actor | When | Action |
|-------|------|--------|
| **Orchestrator (Grok)** | Opening step Kn (`next_actor: implementation`) | Ensure `opt/pre-Kn` exists: run `pre` or ask human to run it **before** Hy3 codes |
| **Orchestrator** | After Gemini **APPROVED**, before advancing | Commit remaining STATE/docs if needed; run `post Kn`; then advance STATE to K(n+1) and immediately `pre` for next step |
| **Hy3** | End of implement (optional) | May commit only if Orchestrator delegated; default: leave commit to Orchestrator post-approve to avoid half-reviewed commits on main history. **Preferred:** Hy3 does **not** push; Orchestrator posts after approve. |
| **Human** | If agents cannot push | Run the same script locally |

**Policy (preferred history):**  
1. `pre Kn` — clean tree before implementation  
2. Hy3 implements (working tree dirty OK)  
3. Gemini reviews  
4. On approve → `post Kn` (all step files + STATE) → advance → `pre K(n+1)`

On **changes_requested**: no new `pre` tag; no `post` until approve. Optional WIP commit `wip(opt): Kn attempt N` only if human wants — not required.

## Rollback

```bash
# Посмотреть точку:
git log --oneline --decorate | head
git tag -l 'opt/*'

# Жёсткий откат к pre-K1 (потеряет незакоммиченное!):
git reset --hard opt/pre-K1

# Или новая ветка с старого checkpoint:
git switch -c recover/pre-K1 opt/pre-K1
```

## STATE fields

```yaml
checkpoint:
  last_pre_tag: opt/pre-K0
  last_post_tag: null   # or opt/K0-done
  last_commit: <short sha or null>
```

Orchestrator updates these when running checkpoints.
