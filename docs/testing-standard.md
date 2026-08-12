# Automated testing standard

This is the canonical testing contract for human and Code Agent changes. It
turns the evidence in [the 18-project research](testing-research.md) into rules
that this repository can execute. The development standard remains authoritative
for architecture and lifecycle; this document is authoritative for test choice,
test shape, and test evidence.

## Definition of a tested change

- **MUST:** Every behavior change adds or updates automated tests in the same
  change. Behavior includes state transitions, Actions and Events, render-visible
  projection, focus/input routing, effects, asynchronous completion, recovery,
  cancellation, lifecycle, persistence/protocol behavior, platform behavior, and
  dependency integration.
- **MUST:** Write the failing behavior test before the implementation when the
  behavior is new or defective. Record the red result in the task context; do not
  commit an intentionally red repository.
- **MUST:** If no automated test can observe changed behavior, the change is
  incomplete until it introduces a stable seam or records a concrete technical
  blocker, a bounded manual check, and follow-up ownership. "UI code" is not an
  exemption.
- **MAY:** Documentation, comments, formatting, or metadata-only edits can omit
  a behavior test when they cannot alter build or runtime behavior. They still
  run the applicable repository contract checks.

Test the lowest stable seam that proves the changed contract, then add a higher
layer only for integration risk that the lower layer cannot detect:

| Layer | Use it for | Stable observation | Canonical command |
|---|---|---|---|
| Pure core | policy, validation, state machine, revision rules | `AppState::dispatch` and `snapshot` | `scripts/test.ps1 -Suite core` |
| Fake adapter | real filesystem/network/database/device boundary with variable outcomes | typed request/result at the adapter interface | package-focused Cargo test |
| GPUI headless | Entity ownership, typed Action/Event, focus/input, component wiring, Task completion, notify/render state | public state/snapshot/event plus `TestAppContext` | `scripts/test.ps1 -Suite gpui` |
| Windows native smoke | process startup, real window/backend, first frame, one Action, native last-window close and bounded exit | self-check marker plus zero exit codes for the finite and interactive launches | `scripts/smoke.ps1` |
| Manual/specialized | DPI, visual fidelity, accessibility, physical devices, installer/signing | named artifact or checklist result | report separately |

The presence of test source or a workflow is not proof that tests ran. The
canonical full gate is `scripts/check.ps1`; it explicitly runs pure core, GPUI
headless, workspace, and Windows smoke layers so a broad Cargo invocation cannot
silently omit the component suite.

Template initialization has a separate generated-repository integration layer:
`scripts/test-generated-project.ps1` runs after the canonical gate in CI. It is
separate to avoid recursive checks and proves clean Git initialization, spaced
paths, Unicode identity, dynamic binary resolution, residual policy, the full
child gate, and release PE resources.

## Scenario contract

For each changed chain, evaluate all rows below. Test every applicable row and
record a current, specific reason for every not-applicable row:

- primary success and observable projection;
- typed recoverable failure and retry/rollback/retain behavior;
- cancellation/reset and a result arriving after cancellation;
- stale or out-of-order completion from a replaced request;
- channel full, coalescing/drop policy, and disconnect;
- owner/View/window removal while work is pending;
- App quit, flush/join/deadline, and late cleanup;
- persistence/protocol migration and rollback;
- unsupported or degraded platform capability.

Do not add imaginary scenarios to a pure subsystem. For example, a module with
no channel records channel capacity as not applicable rather than introducing a
channel solely to test it.

## Determinism and test seams

- **MUST:** Assert observable outcomes through stable module interfaces. Do not
  couple tests to private fields, source text, incidental log wording, executor
  poll counts, or generated layout coordinates.
- **MUST:** Default tests do not use wall-clock sleeps, the public network, user
  files, ambient credentials, physical devices, or unbounded waits. Inject a
  clock or a deterministic adapter only when that real dependency exists.
- **MUST:** Drive asynchronous work explicitly and assert both sides of the
  boundary: state before executor drain and state after completion. Also prove
  the stale/cancel/owner-drop branch where it applies.
- **SHOULD:** Prefer one deep production interface shared by tests over a
  test-only mirror of product behavior. A fake implements a real adapter; it does
  not replace the state machine or GPUI component under test.
- **SHOULD:** Keep tests independent, order-free, bounded, and descriptive in
  product language. A regression test fails for one behavioral reason.

## GPUI and gpui-component recipe

The `app-ui` feature `test-support` enables GPUI's deterministic test runtime.
Shared setup lives in `app_ui::test_support::init_test_app`; it initializes the
same gpui-component globals as production.

1. Use `#[gpui::test]` with `TestAppContext` and create a real test window/View.
2. Focus the actual root when keyboard or Action routing depends on focus.
3. Send the same typed Action used by pointer, keyboard, and menu entry points.
4. Observe an Entity snapshot or typed Event. Use a real gpui-component control
   for one wiring test; prefer Action tests for the rest.
5. Use a stable debug selector only when hit testing itself matters. Resolve its
   bounds at runtime; never assert hard-coded pixels.
6. Use `run_until_parked` to advance deterministic work. Assert the pending
   state before advancing and the committed state afterward.
7. Drop/remove the owning Entity or window while work is pending and verify a
   weak owner cannot be upgraded when lifecycle behavior changes.

Keep setup reusable but small. Do not build a parallel UI driver or page-object
hierarchy until repeated product tests demonstrate that need.

## Agent workflow and evidence

Before implementation, add a test-plan row to the task specification naming the
changed contract, stable seam, lowest layer, red evidence, scenarios, and reason
for omitted higher layers. During implementation:

1. run the narrow test and preserve its expected red failure in task notes;
2. implement the smallest behavior through the production owner/interface;
3. run `scripts/test.ps1 -Suite core` or `-Suite gpui` until green;
4. run `scripts/test.ps1 -Suite all` when the slice is integrated;
5. run `scripts/check.ps1` before completion;
6. report manual, packaging, performance, accessibility, and hosted CI evidence
   separately as passed, failed, or not run.

CI and local automation **MUST NOT** exclude `app-ui` tests or omit the
`test-support` feature. A feature change is not complete when tests exist only in
source, are ignored, are filtered out, or are absent from the required check.
