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

`app-ui` is the GPUI adapter. It owns entities, windows, the application-level
last-window exit policy, render projection, and task/subscription lifetimes.
Product filesystem, database, HTTP, or device integrations should introduce a
seam only when a production adapter and a test adapter both exist.

`desktop` is process glue and the product identity owner. Its Cargo manifest and
build script produce an immutable launch identity plus static Windows resources;
it may choose platform startup flags and call the UI launcher, but it does not
contain application state or rendering. See
[the product identity contract](product-identity.md).

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
| Main window | GPUI application | `app-ui::run` or finite `run_smoke` | GPUI removes the closed window; the application policy requests quit only when no windows remain | 15-second native smoke deadlines for first-frame self-check and interactive last-window close | No application data to flush | Startup error to stderr; smoke returns failure; see [the startup failure baseline](#startup-failure-baseline) | GPUI releases the window; no product resource currently outlives it |
| Last-window close `Subscription` | App-global `ApplicationLifecycle` | `run_with_mode` after gpui-component initialization | One application-lifetime observer; no stale identity required | Event-driven on the GPUI foreground context | Dropping the App-global owner unsubscribes; no flush | Infallible zero-window check; process-level timeout reports a missing exit | Observer checks `cx.windows().is_empty()` and calls `cx.quit()`; App shutdown drops the owner |
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

### Startup failure baseline

If GPUI rejects main-window creation, `app-ui` writes the error to stderr and
requests application quit. The interactive launcher does not promise a non-zero
process exit code for this platform failure. This is a template baseline, not a
general product recovery contract.

The locked GPUI test platform currently always creates windows successfully.
The template therefore does not add a test-only window opener, fake platform,
or failure-only launch mode to simulate this branch. The native Windows smoke
remains the acceptance evidence for successful startup and rejects a process
that exits before exposing its main window; it does not inject window-creation
failure.

Revisit this baseline when a real launcher, installer, or supervisor consumes
the process exit status; a production incident demonstrates the need; or GPUI
provides deterministic window-creation failure injection.

## Testing strategy

- `scripts/test.ps1 -Suite core` tests state through `AppState::dispatch` and
  `snapshot` without GPUI.
- `scripts/test.ps1 -Suite gpui` enables GPUI `test-support`, initializes the
  real gpui-component globals, and tests the production Entity through typed
  Actions, a real Button click, deterministic Task drain/cancel, and owner drop.
- `scripts/smoke.ps1` is a distinct native-backend layer. Its finite self-check
  reaches a frame, handles a typed Action, verifies state on a second frame, and
  exits through the last-window policy. A second normal launch receives a native
  main-window close request and must exit within the process deadline.
  Specialized visual, DPI, accessibility, and installer evidence remains
  separately named.
- Introduce a deterministic fake clock/filesystem/backend only when the real
  production dependency varies; do not expose internal seams solely for tests.

The normative layer/scenario/evidence rules are in
[the automated testing standard](testing-standard.md).
