# AuraSplitter workflow steps

## MATRIX_HARDENING — Automation Matrix

**Pipeline profile:** standard  
**Risk:** medium  
**Purpose:** repair matrix stem-selection interaction and make the keep/drop contract explicit without changing separation-engine behavior.

**Source of truth:**
- `Sources/AuraSplitterApp/Models/AutomationModels.swift`
- `Sources/AuraSplitterApp/Models/AutomationWizardStore.swift`
- `Sources/AuraSplitterApp/Views/Automation/AutomationWizardView.swift`
- `Sources/AuraSplitterApp/Services/AutomationProcessRunner.swift`
- `tests/AuraSplitterAppTests/AutomationMatrixTests.swift`

**Preserve:** existing preset catalog, model IDs, runner sequencing, and unrelated dirty-tree work.  
**Do not change:** backend separation behavior, persistence formats, or unrelated UI.

### Definition of done

#### Implementation

- [x] MATRIX_HARDENING.D1 — Register canonical matrix work item
- [x] MATRIX_HARDENING.D2 — Reconcile state and plan files
- [x] MATRIX_HARDENING.D3 — Finish matrix selection hardening
- [x] MATRIX_HARDENING.D4 — Review matrix implementation

#### Objective gates

- [x] MATRIX_HARDENING.O1 — `swift test --filter AutomationMatrixTests`
- [x] MATRIX_HARDENING.O2 — `swift test`
- [x] MATRIX_HARDENING.O3 — `./script/build_and_run.sh` smoke check when environment permits

#### Judgment gates

- [x] MATRIX_HARDENING.J1 — Reviewer confirms matrix keep/drop semantics, click targets, state publication, scope, and regressions
- [x] MATRIX_HARDENING.J2 — Main confirms release readiness and version `1.1.2`

#### Release

- [x] MATRIX_HARDENING.D5 — Publish version 1.1.2
