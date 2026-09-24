# Testing guide

Apply [foundation verification](../agent-foundation/verification.md) for scope,
evidence reuse and environment-blocked checks. This guide owns project commands.

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

## Commands and selection

`scripts/check.ps1` defaults to the full local gate. `-Group`
accepts one or more groups, deduplicates shared steps, and reports only selected
coverage. Use focused commands during development and affected groups at feature
handoff. Integration/release requires the full gate and relevant manual acceptance.

Hosted CI runs `scripts/check.ps1 -Group docs,static,tests,build,validators` and
`scripts/test-generated-project.ps1 -SkipGui`. Core and GPUI headless tests remain
required. Real-window startup and all native Overlay suites are local acceptance;
there is currently no dedicated interactive runner. A green CI run establishes
only the desktop-independent coverage, not GUI acceptance.

On an unlocked Windows desktop, run `scripts/check.ps1 -Group startup,overlay`
for local GUI acceptance (or `scripts/check.ps1` for the complete local gate).
For template generation changes, also run `scripts/test-generated-project.ps1`
locally. Record the tested commit, command, result and any environment blockers;
follow the [Overlay manual checklist](overlay-manual-acceptance.md) for visual
and display-specific acceptance. These scripts remain automated local tests.

| Change / purpose | Command |
|---|---|
| Documents or agent guidance | `scripts/check.ps1 -Group docs` and `git diff --check` |
| Foundation link checker | `scripts/test-docs.ps1` (isolated positive/negative fixtures) |
| Gate routing | `scripts/test-check-routing.ps1` (isolated dispatch/failure tests) |
| Static Rust/dependency/architecture checks | `scripts/check.ps1 -Group static` |
| Domain behavior | `scripts/test.ps1 -Suite core` |
| UI entities and event wiring | `scripts/test.ps1 -Suite gpui` |
| All Rust behavior tests | `scripts/check.ps1 -Group tests` (one workspace all-features run) |
| Windows executable and PE resources | `scripts/check.ps1 -Group build` |
| Process startup/exit | `scripts/check.ps1 -Group startup` (includes build) |
| Overlay behavior | `scripts/smoke-overlay.ps1 -Suite <affected-suite>` |
| All Overlay native scenarios | `scripts/check.ps1 -Group overlay` |
| Verification tooling | `scripts/check.ps1 -Group validators` |
| Complete integration | `scripts/check.ps1` (optional `-IncludeIme`) |

Native tests need the environment described in [Windows rules](windows-platform.md).
An environment abort is BLOCKED, not PASS; resume its focused suite when the
prerequisite changes. `-IncludeIme` requires `all` or `overlay`. Native smoke does
not certify visual quality, physical DPI changes or hosted CI success.

`scripts/test-generated-project.ps1` applies when initialization, product identity,
UI dependencies or build integration affect generated applications. The default
checks spaced paths, Unicode names, initialization, architecture, documentation,
build, native startup, reconfiguration and Release resources. Component behavior
is already covered in the source project. Use `-FullRegression` when generation
can affect that behavior; `-IncludeIme` also selects full generated regression.
Initialized products skip this template-only fixture based on binary identity.

The hosted `-SkipGui` option omits native startup while preserving initialization,
architecture, docs, builds and resource checks; it rejects `-FullRegression` and
`-IncludeIme` combinations so GUI work cannot be silently discarded.

A new Overlay assertion alone does not require generated-project regression.
After a gate failure, rerun affected groups and groups not yet reached. A changed
shared window driver can invalidate several native suites; a Demo label or an
acceptance-note edit does not automatically invalidate them all.

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
