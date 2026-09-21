# GPUI implementation

`app-ui` owns GPUI Kit setup, entities, local interaction state, Action/Event
routing, focus and effect execution. Apply
[implementation rules](../../docs/agent-development-standard.md); domain
transitions stay in `app-core`.

For changed UI behavior, use `#[gpui_kit::test]`, `TestAppContext` and
`test_support::init_test_app`. Drive production Actions and observe state or
Events. For actual pointer routing, use Kit's `TestWindowExt` with the
component ElementId. Advance async work deterministically and cover affected
cancel/stale/owner-drop paths.

Focused check: `scripts/test.ps1 -Suite gpui`. Startup and native lifecycle
changes also need [Windows smoke](../../docs/windows-platform.md).
