# DESIGN_V2 — AuraSplitter UI/UX steps

> **Track:** `DESIGN_V2`  
> **Roles:** Grok orchestrator · Hy3 implementer · Gemini 3.5 Flash reviewer  
> **Gate:** after Gemini approve → **live app visual check** by Grok (+ Human) before post-tag  
> **Git:** `design/pre-Dn` before Hy3; `design/Dn-done` after visual PASS + push  

OPT_PERF (K0–K8) is **closed**. Do not reopen K* unless human asks.

## Roles reminder

| Role | Model | Action |
|------|--------|--------|
| Orchestrator | Grok | STATE, git pre/post + push, open build, visual accept/reject, fix_prompt |
| Implementation | **Hy3 / Hi3** | code only `target_files`; refuse if `design/pre-Dn` missing |
| Verification | **Gemini 3.5 Flash** | FEEDBACK.md — does **not** replace visual gate |

## Cycle

```text
pre-tag+push → Hy3 → Gemini → (fix loop) → build+visual → post-tag+push → next step
```

## Steps overview

| Step | Name | Visual focus |
|------|------|----------------|
| **D0** | Branding + logo + Kirtan→Aura titles | Title, dock icon, model names |
| **D1** | Process preset → Custom | Heavy + edit segment → Custom |
| **D2** | Results chrome | Compare-only menu; Info→Folder→Trash |
| **D3** | Settings sidebar | Model → Process → Presets; no Override |
| **D4** | Eye visibility | Header menus filter |
| **D5** | Honest Est. time | Est. moves with knobs |
| **D6** | Waveform + sliders | Filled blue wave; sliders on main |
| **DESIGN_DONE** | Acceptance | Full checklist |

---

## D0 — Branding (AuraSplitter)

### Цель
Product reads as **AuraSplitter** with a new mark; user-facing **Kirtan** titles become **Aura**.

### Требования
1. Window / toolbar title: **AuraSplitter** (capital S).
2. New logo: concentric aura / split shell + center **A**; cyan→blue→violet; ship `LOGO/AuraSplitter.svg` and rebuild app `.icns` via existing icon script / `build_and_run.sh`.
3. Do **not** reuse the old KirtanSplitter glyph.
4. User-facing preset/model titles: replace leading **Kirtan** with **Aura** in:
   - `backend/kirtan_backend/presets.py`
   - `backend/kirtan_backend/model_catalog.py` (`title` / `displayName`)
5. Soften copy that says “kirtan recording” → neutral “recording” / “audio”.
6. **Keep** internal IDs (`kirtan_pro`, …), Python package name, App Support path `KirtanSplitter`, bundle id — **no path migration** in D0.
7. Update tests that assert old display strings.

### Visual acceptance
- [ ] App title shows AuraSplitter
- [ ] Dock/app icon is the new mark (not old logo)
- [ ] Model/preset menus show Aura Pro, Aura Vocal Elite, etc. (no “Kirtan …” user titles)

### Не делать
- Custom dirty, eyes, estimate math, waveform fill, sidebar reorder

### target_files
- `LOGO/AuraSplitter.svg` (NEW)
- `script/build_and_run.sh` (icon path if needed)
- `script/make_app_icon.sh` (only if needed)
- `Sources/KirtanSplitterApp/Views/ContentView.swift`
- `Sources/KirtanSplitterApp/Views/ResultsPaneView.swift` (copy only)
- `backend/kirtan_backend/presets.py`
- `backend/kirtan_backend/model_catalog.py`
- Tests that hardcode `"Kirtan` display titles

### Done
- Branding requirements met; swift build; relevant pytest; visual PASS

---

## D1 — Process preset → Custom

### Цель
If process knobs diverge from selected process-preset snapshot, UI shows **Custom**, not a lying “Heavy”.

### Требования
1. Compare live `SeparationSettings` to `ProcessSettingsSnapshot` of selected process preset (format, speed, chunk, segment, overlap, batch, override flags, performanceFlags).
2. Match → display preset title; dirty → **Custom** in toolbar process chip/picker and settings sidebar.
3. Re-selecting a preset re-applies snapshot.
4. Unit tests for match/dirty helper.

### Visual acceptance
- [ ] Select Heavy, change Segment → UI shows Custom
- [ ] Select Heavy again → params restore, label Heavy

### Не делать
- Eyes, branding, estimate backend

### target_files
- `Sources/KirtanSplitterApp/Models/ProcessSettingsPreset.swift`
- `Sources/KirtanSplitterApp/Views/ContentView.swift`
- `Sources/KirtanSplitterApp/Views/ControlPaneView.swift`
- `tests/KirtanSplitterAppTests/ProcessSettingsPresetTests.swift` (or new)

### Done
- Dirty detection + labels; tests; visual PASS

---

## D2 — Results: menu + row icons

### Цель
Context menu = Compare only. Row actions as icons: Info → Folder → Trash.

### Требования
1. Context menu: **only Compare** (≥2 selected enables; else disabled hint). Remove Info / Reveal / Delete from menu.
2. Stem row icons order: **ⓘ Info** | **folder** | **trash**.
3. Info opens existing `StemInfoSheet` (sidecar run info).
4. Folder = Reveal in Finder; trash = delete stem (keep current behavior).

### Visual acceptance
- [ ] Right-click shows only Compare
- [ ] Three icons present in order Info, Folder, Trash
- [ ] Info sheet opens from ⓘ

### Не делать
- Sidebar redesign, branding

### target_files
- `Sources/KirtanSplitterApp/Views/SourceResultOverviewView.swift`
- `Sources/KirtanSplitterApp/Views/ResultsPaneView.swift` (if duplicate actions)

### Done
- Menu + icons; visual PASS

---

## D3 — Settings sidebar order

### Цель
Clear Process tab: Model → Process Settings → Settings Presets; remove Model Override clutter.

### Требования
1. Order: **Model** (single picker) → **Process Settings** → **Settings Presets**.
2. Remove separate **Model Override** block; one model control is enough.
3. Put Speed / Override Model Segment / Keep Converted under **Advanced** disclosure.
4. Format, Chunk, Segment, Overlap, Batch stay primary.

### Visual acceptance
- [ ] No “Model Override” section
- [ ] Order matches Model → Process → Presets
- [ ] Advanced hides secondary toggles by default

### target_files
- `Sources/KirtanSplitterApp/Views/ControlPaneView.swift`
- Related settings bindings in `ContentView.swift` only if required

### Done
- Layout + visual PASS

---

## D4 — Eye visibility (models + process presets)

### Цель
Header dropdowns show only “favorited” (eye ON) models and process presets.

### Требования
1. Full lists in Settings: eye toggle per model and per process preset (built-in + custom).
2. Eye ON → appears in **header** model / process menus; OFF → hidden from header only.
3. Persist (UserDefaults or App Support JSON).
4. Always show **current selection** and **Custom** even if base eye is off.
5. Default: all visible (or document chosen default).

### Visual acceptance
- [ ] Turn off eye on Fast → Fast gone from header process menu
- [ ] Turn off eye on a model → gone from header model menu
- [ ] Settings still lists hidden items with eyes

### target_files
- New store e.g. `Sources/KirtanSplitterApp/Models/MenuVisibilityStore.swift` (or Support/)
- `ControlPaneView.swift` / Models UI
- Header pickers in `ContentView.swift`
- Optional small tests

### Done
- Persistence + filtering; visual PASS

---

## D5 — Est. time from real knobs

### Цель
`Est.` must change when Segment / Batch / Overlap / Chunk change — not stuck on Heavy median only.

### Требования
1. Extend `render_estimates` to prefer samples matching model + real settings (segment, batch, overlap, chunk, …).
2. Fallback: nearest samples + conservative scale heuristic; document in code comments.
3. Client sends knobs in `render_estimate` params (not only processPresetID).
4. Tooltip: predicted wall time from past runs; updates with settings.
5. Pytest coverage for knob-sensitive estimates.

### Visual acceptance
- [ ] With calibration data or heuristic, changing segment/batch changes Est. display
- [ ] Tooltip explains Est.

### target_files
- `backend/kirtan_backend/render_estimates.py`
- Engine/protocol path that builds estimate params
- `Sources/KirtanSplitterApp/Services/BackendClient.swift`
- `Sources/KirtanSplitterApp/Models/BackendModels.swift` (display/tooltip if needed)
- `Sources/KirtanSplitterApp/Views/ContentView.swift` (Est. chrome)
- `tests/test_render_estimates.py`

### Done
- Backend + UI + tests; visual PASS

---

## D6 — Filled waveform + main sliders

### Цель
Waveform is a **filled** blue envelope; Spectrum/Waveform intensity controls live on the main preview bar.

### Требования
1. `drawWaveform`: primary look = filled blue area under/inside envelope; stroke secondary or thin.
2. Spectrum intensity still drives spectrogram colormap gain (existing behavior).
3. Spectrum + Waveform sliders visible on main preview toolbar (not only popover).
4. Popover optional (e.g. Reset only) or removed if redundant.

### Visual acceptance
- [ ] Waveform looks filled blue, not outline-only
- [ ] Both sliders visible without opening a menu button
- [ ] Spectrum slider still affects spectrogram intensity

### target_files
- `Sources/KirtanSplitterApp/Views/AudioPreviewPane.swift`

### Done
- Visual PASS

---

## DESIGN_DONE — Acceptance

- [ ] AuraSplitter title + new icon
- [ ] Aura* preset/model display titles
- [ ] Custom when process knobs dirty
- [ ] Results: Compare-only menu; Info → Folder → Trash
- [ ] Sidebar order; no Model Override
- [ ] Eyes filter header menus
- [ ] Est. responds to knobs
- [ ] Filled waveform; main Spectrum/Waveform sliders
- [ ] All steps have `design/pre-Dn` + `design/Dn-done` on GitHub

`next_actor: human` when DESIGN_DONE.

---

## Verify commands

| Stack | Command |
|-------|---------|
| Python | `.venv/bin/pytest tests/ -q` (or subset for step) |
| Swift | `swift build` and/or `swift test` |
| App | `./script/build_and_run.sh` for visual gate |
