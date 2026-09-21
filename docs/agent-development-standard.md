# Implementation rules

These rules translate a product spec into this Rust/GPUI template. The developer
owns product behavior; the Agent chooses implementation details within that
scope. Keep changes directed at the requested result.

## Ownership and boundaries

- Preserve `desktop -> app-ui -> app-core`. Domain state and decisions belong
  in `app-core`; GPUI entities, transient interaction state and effect execution
  belong in `app-ui`; `desktop` owns process startup and product identity.
- Give mutable state one write owner. Snapshots are read projections. Keep local
  focus, hover and input state local rather than forcing it into the domain.
- Use enums for mutually exclusive phases and typed requests/results for
  effects. Avoid parallel caches or alternate handlers for the same state.
- Reuse adjacent patterns. Introduce a trait or service boundary for a real
  varying dependency, including a required deterministic test adapter, rather
  than a hypothetical future system.

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

## Resources and failures

- Every task, subscription and external resource has an owner and stop path.
  Keep simple ownership evident in fields and code. Document interacting
  workers, external artifacts or shutdown ordering when code alone is unclear.
- Dropping a UI task is sufficient only for work whose cancellation leaves no
  required cleanup. Define how pending writes, workers and partial artifacts
  finish, cancel or clean up, including late results after owner removal.
- Keep synchronous locks out of await boundaries. Blocking I/O and worker joins
  run off the UI thread. Detached work needs an application/process owner.
- Choose channel capacity and full/disconnect behavior deliberately. Bound
  potentially large queues, materialization and caches as well as visible UI.
- User-triggered failures reach typed recovery state with a useful action.
  Preserve error classification internally and redact user content and secrets
  from logs and diagnostics. External failures are not unwrap/expect invariants.
- When resources require flush, drain or confirmation, close and Quit converge
  on one shutdown path. Consult [architecture](architecture.md) and the
  [Windows guide](windows-platform.md) for platform ownership.

## Keep requirements and evidence aligned

Test observable behavior at the lowest stable seam using
[the testing guide](testing-standard.md). Preserve existing regression coverage.
Changing a test or checker to reflect an intentional contract change requires
an explanation and coverage of the replacement; hiding failures by skipping,
deleting assertions or relaxing requirements is not a fix.

Update documentation when a public contract or non-obvious design reason
changes. Use [ADRs](decisions/README.md) for durable cross-cutting choices, not
routine local refactors. Add a persistent Agent rule only for a demonstrated,
recurring trap that changes how work is done; prefer a type, test or existing
check when it can express the requirement.
