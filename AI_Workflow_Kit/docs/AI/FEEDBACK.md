# FEEDBACK — DESIGN_V2

## Track status
**DESIGN_V2 = DONE** (D0–D6 all Gemini-approved + orchestrator visual gate).

| Step | Tag | Summary |
|------|-----|---------|
| D0 | design/D0-done | AuraSplitter brand, logo, Aura titles, paths |
| D1 | design/D1-done | Process preset → Custom when dirty |
| D2 | design/D2-done | Results: Compare-only menu; Info→Folder→Trash |
| D3 | design/D3-done | Sidebar Model → Process → Presets; Advanced |
| D4 | design/D4-done | Eye visibility (+ compact dropdown fix) |
| D5 | design/D5-done | Est. from real knobs + tooltip |
| D6 | design/D6-done | Filled waveform; Spectrum/Waveform on main toolbar |

## Last step: D6 — APPROVED (Gemini) + visual PASS (orchestrator)

- Filled blue waveform envelope (stronger fill, thinner stroke)
- Spectrum + Waveform sliders on main preview chrome
- Layer popover removed

## No pending review

Optional human follow-ups: full binary/bundle rename, delete old KirtanSplitter data folders after migration, further logo polish.

---

# FEEDBACK — MATRIX_HARDENING

## 2026-08-31 reviewer verdict

**APPROVED** — no blocker, major, or minor findings.

Reviewed scope:
- `Sources/AuraSplitterApp/Models/AutomationModels.swift`
- `Sources/AuraSplitterApp/Models/AutomationWizardStore.swift`
- `Sources/AuraSplitterApp/Views/Automation/AutomationWizardView.swift`
- `Sources/AuraSplitterApp/Services/AutomationProcessRunner.swift` (verified unchanged)
- `tests/AuraSplitterAppTests/AutomationMatrixTests.swift`

Judgment evidence:
- each matrix role has a non-overlapping 36×36 target and stable
  `step{1|2}-track-model-stem` identity;
- `MatrixScrollChromeNSView.hitTest` returns `nil`, so scroll chrome cannot
  swallow role clicks;
- model catalogs prune unsupported/stale roles, deselected parents, and removed
  Step-1 sources before Step 2 or process start;
- nested matrix/name mutations reassign `@Published` state;
- focused regression tests cover role scoping, catalog filtering, Step-2
  derivation/pruning, validation, and publication.

Runtime/build evidence remains pending Tester; this review is source/diff
approval only.

---

## 2026-08-31 QA verdict

**QA GREEN** — all three objective gates passed once:

- `swift test --filter AutomationMatrixTests`: 7 tests, 0 failures, exit 0.
- `swift test`: 99 tests, 0 failures, exit 0.
- `./script/build_and_run.sh`: exit 0; debug build succeeded, staged
  `dist/AuraSplitter.app`, backend listened on `127.0.0.1:51273`, and the app
  launched with PID 92491.

Runtime observations:
- Automation wizard opened at Matrix with 12 live tracks and 3 model columns:
  Aura Pro (6 stem slots), Aura Vocal Pro (2), and Aura Back Vocal (2).
- Stem controls exposed `keep`/`skip` accessibility values; one live keep state
  was observed. Final-name fields were populated for all 12 tracks.
- QA did not execute live cross-column click toggling, Step-1 deselection
  pruning, or final-name edit retention because the user was concurrently
  driving the same app instance and closed the window during the probe.
  Store-level regression coverage verifies those three behaviors (7/7).
- QA generated no source/workflow changes; the pre/post QA dirty-tree checksum was identical. Generated ignored build artifacts were not included.
---

## 2026-09-01 release preparation

`./script/release.sh 1.1.2 --no-publish` completed with exit 0 in 707.52s.
The release build set `VERSION`, `CFBundleShortVersionString`, and
`CFBundleVersion` to `1.1.2`.

Notarized artifacts:
- `dist/AuraSplitter-arm64.dmg` — 384,921,024 bytes; SHA-256
  `93252ca393480f0544e681f084559d9493e496b0baa7ba55ab22b757585e326e`
- `dist/AuraSplitter-arm64.zip` — 282,513,025 bytes; SHA-256
  `4423ad97ec26a9f9f1d1ee56c802067e564e632634bb5e3e13772479a4955d3b`

`codesign --verify --deep --strict`, `xcrun stapler validate` for the app and
DMG, `spctl` Developer ID acceptance, and `mlx-audio-io` preflight all passed.
Notary submissions were accepted for both app and DMG. GitHub publication was
intentionally not performed by the preparation command; artifacts are ready
for the final publish step.

---

## 2026-09-01 release publication

Published stable GitHub release `v1.1.2` at
https://github.com/Pavan-Gopa/AuraSplitter/releases/tag/v1.1.2.

- Release target: commit `b26692d339d2072bd4c2aaa5d2e01d5cc105682c`
- `isDraft: false`
- `isPrerelease: false`
- `AuraSplitter-arm64.dmg`: uploaded, 384,921,024 bytes,
  SHA-256 `93252ca393480f0544e681f084559d9493e496b0baa7ba55ab22b757585e326e`
- `AuraSplitter-arm64.zip`: uploaded, 282,513,025 bytes,
  SHA-256 `4423ad97ec26a9f9f1d1ee56c802067e564e632634bb5e3e13772479a4955d3b`

The first publish attempt was rejected because GitHub did not accept the
abbreviated `--target b26692d`; the retry with the full commit SHA succeeded.
