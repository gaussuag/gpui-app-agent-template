# Testing guide

Use the developer's acceptance criteria as the test target. Add or update
automated tests with behavior changes at the lowest stable seam. For a bug,
first reproduce it with a failing test where feasible. Test-first development
is useful but recording a red result is not a universal paperwork requirement.

## Choose the relevant layer

| Changed behavior | Evidence |
|---|---|
| Domain transitions, validation, revision handling | Pure core tests through public state/commands |
| External I/O or variable backend outcomes | Adapter tests with deterministic success/failure inputs |
| Entity, Action, component, focus or event wiring | GPUI Kit headless tests on production entities |
| Async completion or resource lifetime | Applicable completion, replacement/stale, cancellation and owner-drop tests |
| Startup, native backend, last-window exit | Windows process smoke |
| Identity, template generation or UI-stack/build integration | Generated-project fixture and built PE resources |
| Layout, DPI, accessibility or installer behavior | Actual visual/manual or specialized checks |

Test scenarios introduced or affected by the change. Unrelated channel,
migration or shutdown scenarios do not require empty rows or not-applicable
reports. A visual-only adjustment can use visual evidence when an automated
assertion would merely duplicate styling. If a meaningful behavior test cannot
run, state the limitation and remaining acceptance work.

## Commands and final verification

- `scripts/test.ps1 -Suite core`: fast domain feedback.
- `scripts/test.ps1 -Suite gpui`: GPUI Kit tests with `test-support`.
- `scripts/test.ps1 -Suite all` (or `workspace`): one workspace all-features run,
  including core, UI and desktop tests without separately repeating them.
- `scripts/check.ps1`: formatting, Clippy, workspace tests, documentation links,
  identity/dependency validator fixtures, architecture, Windows build, PE
  resources and native smoke. Required before delivering code/build/automation
  changes; CI uses the same entry.
- Documentation-only changes: `scripts/check-docs.ps1` and `git diff --check`.
- `scripts/test-generated-project.ps1`: additionally required when initialization,
  identity, UI dependencies, or build/verification scripts change generated
  applications. Template CI runs it; initialized products skip it based on their
  Cargo binary identity. It checks spaced paths, Unicode names, initialization,
  reconfiguration, the child gate and release resources.

Report actual outcomes, identifying failures and unrun relevant checks. A
native smoke pass does not establish visual quality, manual DPI, accessibility,
installer behavior or hosted CI success. Do not rerun an unchanged passing
suite unless new evidence calls its result into question.

## GPUI test recipe

Initialize the real Kit globals using `app_ui::test_support::init_test_app`.
Create the production Entity/View and focus it if routing needs focus.
Dispatch its typed Action and observe state or Events. Use Kit's
`TestWindowExt` and a component ElementId when pointer wiring itself matters.

Advance asynchronous work explicitly with the deterministic executor. Observe
pending state before completion, then the result; exercise stale/cancel/drop
paths when affected. Avoid wall-clock sleeps, public network, user files and
unbounded waits. Introduce fake clocks or I/O adapters for real dependencies,
not a parallel implementation of product behavior.

Checkers that change acceptance need positive and negative fixtures proving
the intended requirement. Keep fixtures isolated from user data and Git
configuration. Full logs may be saved as local artifacts; the task handoff
needs a concise result and a reproducible acceptance path.
