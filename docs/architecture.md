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

| Resource | Owner | Start | Cancel/stale identity | Deadline | Join/flush | Error destination | Owner drop/late cleanup |
|---|---|---|---|---|---|---|---|
| Main window | GPUI application | `app-ui::run` | Window close/application quit | GPUI platform contract | No application data to flush | Startup error to stderr; future recoverable startup errors need UI/launcher state | GPUI releases the window; no product resource currently outlives it |
| Demo work `Task` | `TemplateView` | `Effect::RunWork` | Replaced/reset; request revision rejects a late result | No external wait; bounded deterministic CPU loop | Dropped, not joined; no external artifact | Infallible demo; a real adapter extends typed `WorkStatus` with recovery | Entity drop cancels the UI task; late revision cannot commit |
| Domain state | `TemplateView` | Entity construction | Reset increments revision | In-process transition | Nothing to flush | Commands return explicit effects | Entity drop releases state |

Every new task, subscription, worker, channel, watcher, or native handle adds a
row with all fields. Persistent writes and temporary artifacts are resources too.
If an owner, deadline/contract, error destination, or late-cleanup path cannot be
named, lifecycle design is incomplete. Use
[the full ledger template](templates/lifecycle-ledger.md) when resources interact.

The sample has no fallible external I/O and therefore does not demonstrate a
complete error or shutdown coordinator. Introduce those protocols with the first
real resource that requires recovery, flush, join, or confirmation; do not infer
them from this CPU-only example.

## Testing strategy

- Test state behavior through `AppState::dispatch` and `snapshot`.
- Test adapters through observable results at their seam.
- Keep platform smoke tests separate from pure state tests.
- Prefer a deterministic fake clock/filesystem/backend when the production
  dependency genuinely varies; do not expose internal seams solely for tests.
