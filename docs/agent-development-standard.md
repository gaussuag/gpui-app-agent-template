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
- Render is a repeatable, side-effect-free projection of prepared state and
  never starts tasks. Action handlers may perform lightweight state transitions
  and start or replace owned tasks.
  External I/O, heavy work and blocking waits execute off the foreground thread.
  Trace the actual work body; async syntax or a Task return type does not prove
  background execution.
- Background work takes suitable owned inputs and returns results. Route results
  through a valid GPUI context to the state owner's acceptance logic, following
  [foundation async rules](../agent-foundation/engineering.md).
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
