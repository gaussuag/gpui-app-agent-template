# Architecture

## Dependency direction

```text
desktop -> app-ui -> app-core
              |
              +----> gpui + gpui-component
```

`app-core` is a deep module: callers learn the `dispatch`/`snapshot` interface,
while state transitions, revisions, and stale-result rules remain local. It has
no hypothetical adapter because its dependencies are in-process and pure.

`app-ui` is the GPUI adapter. It owns entities, windows, render projection, and
task lifetimes. Product filesystem, database, HTTP, or device integrations
should introduce a seam only when a production adapter and a test adapter both
exist.

`desktop` is process glue. It may choose platform startup flags and call the UI
launcher, but it does not contain application state or rendering.

## State and effect flow

```text
input callback
  -> AppState::dispatch(Command)
  -> snapshot updated immediately
  -> Effect returned
  -> app-ui starts/replaces owned Task
  -> immutable WorkResult returns
  -> foreground entity update
  -> revision gate in AppState
  -> cx.notify()
  -> render reads a new Snapshot
```

Render is repeatable and side-effect free. It never starts work, reads files,
waits on channels, sleeps, or acquires long-lived locks.

## Lifecycle ledger

| Resource | Owner | Start | Stop/cancel | Failure surface |
|---|---|---|---|---|
| Main window | GPUI application | `app-ui::run` | Window close/application quit | Startup error to stderr |
| Demo work `Task` | `TemplateView` | `Effect::RunWork` | Replaced, reset, or entity drop | Extend `WorkStatus` for fallible work |
| Domain state | `TemplateView` | Entity construction | Entity drop | Commands return explicit effects |

Every new task, subscription, worker, channel, watcher, or native handle adds a
row. If its stop path cannot be named, its lifecycle design is incomplete.

## Testing strategy

- Test state behavior through `AppState::dispatch` and `snapshot`.
- Test adapters through observable results at their seam.
- Keep platform smoke tests separate from pure state tests.
- Prefer a deterministic fake clock/filesystem/backend when the production
  dependency genuinely varies; do not expose internal seams solely for tests.
