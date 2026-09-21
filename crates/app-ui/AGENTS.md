# app-ui owner contract

This file extends [the repository contract](../../AGENTS.md) for the only GPUI Kit
adapter.

## Owner and interface

`app-ui` owns Application/window setup, GPUI Entity trees, Kit component Root
and theme projection, Action/Event/Focus routing, render projection, adapter
effects, and UI-scoped Task/Subscription lifetimes. Product state transitions
remain in `app-core`.

## Boundaries

- Interpret `app-core::Effect`; do not duplicate its state machine in callback
  fields or UI booleans.
- Update UI state only through GPUI context boundaries. Background closures take
  immutable Send input and return immutable output.
- Store every Task, Subscription, receiver, watcher, or native handle in its
  Entity/App owner. Add its full lifecycle row to `docs/architecture.md`.
- Check owner existence and request identity before foreground commit. Clean up
  resources created by a late result.
- Render only snapshots and prepared UI state. Perform I/O, waiting, task
  creation, and expensive preparation before render.
- Route equivalent pointer, keyboard, and menu intents through one handler;
  preserve focus ownership and restoration for interactive overlays.
- Map typed failures to recovery UI and redacted diagnostics; a log-only result
  is reserved for explicitly best-effort maintenance.

## Validation

Apply [the automated testing standard](../../docs/testing-standard.md). Use
`#[gpui_kit::test]`, `TestAppContext`, and `test_support::init_test_app` for changed
Entity, Action/Event, focus, component, async completion, or owner-drop behavior.
Drive the production typed Action and observe state/Event output; use Kit's
`TestWindowExt` with the component ElementId for real pointer hit routing.

Focused command:

```powershell
.\scripts\test.ps1 -Suite gpui
```

Runtime behavior also needs the applicable Windows smoke cases in
`docs/windows-platform.md`. A new async or native resource requires task-spec
lifecycle, cancellation/late-result, failure, and close evidence.
