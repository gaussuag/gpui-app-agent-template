# Implementation rules

These rules translate a product spec into this Rust/GPUI template. The developer
owns product behavior; the Agent chooses implementation details within that
scope. Keep changes directed at the requested result.

Shared ownership, async, error-handling and investigation rules live in
[foundation engineering](../agent-foundation/engineering.md).

## Project ownership

Preserve `desktop -> app-ui -> app-core`. Domain state and decisions belong in
`app-core`; GPUI entities, transient interaction state and effect execution belong
in `app-ui`; `desktop` owns process startup and product identity. Native Overlay
operations stay in `overlay-win32/src/windows`, called through the UI native bridge.

## GPUI execution

- Use APIs from the locked dependency source and current working examples.
  Upstream main and remembered GPUI APIs may target another version.
- Render projects prepared state. External I/O, heavy work, blocking waits and
  task creation belong outside render and outside the foreground action path.
- Background work takes suitable owned inputs and returns results. Commit
  UI-observable changes through a valid GPUI context after checking both owner
  liveness and request revision/key. Liveness alone does not establish relevance.
- Keep equivalent keyboard, menu and pointer intents on one Action/handler.
  Retain Subscriptions in their owners and preserve focus routing/restoration.
- Notify after state changes. Add coalescing or finer invalidation when actual
  update frequency requires it.

## Platform lifetime

Blocking I/O and worker joins run off the UI thread. Detached work needs an
application/process owner. When cleanup requires flush, drain or confirmation,
close and Quit converge on one shutdown path. Consult [architecture](architecture.md)
and [Windows rules](windows-platform.md) for the concrete ownership protocol.

Use [testing](testing-standard.md) to select checks. Lasting project decisions
belong in [ADRs](decisions/README.md), not in the foundation.
