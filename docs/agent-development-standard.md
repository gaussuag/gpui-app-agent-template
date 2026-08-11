# Agent development standard

This is the normative engineering reference for Code Agent changes in this
repository. `MUST` protects correctness, lifecycle, evidence, or a repository
invariant. `SHOULD` is the default and needs a recorded reason to diverge.
`AVOID` identifies a repeatedly risky shape; use its stated positive design or
an ADR-backed exception.

## Authority and change scope

- **MUST:** Treat current source, manifests, lockfile, scripts, and scoped
  instructions as facts. Treat plans, comments, README claims, and prior chat as
  navigation until current code confirms them.
- **MUST:** Trace the existing entry-to-render/error/shutdown chain before a
  runtime edit. A callback, reducer, completion handler, and exit hook are one
  behavior even when they live in different files.
- **MUST:** Keep the diff to the requested outcome and preserve unrelated user
  changes. Dependency upgrades and opportunistic refactors use separate tasks
  and commits.
- **SHOULD:** Reuse an adjacent owner pattern and stable test seam. Introduce a
  new seam only for real variation, not a predicted future implementation.
- **SHOULD:** Keep public interfaces small and deep. Document state/resource
  owner, caller context, invariants, errors, cancellation, and platform limits.

## Dependency and state ownership

- **MUST:** Preserve `desktop -> app-ui -> app-core`. `app-core` remains free of
  GPUI, windows, native APIs, and external I/O.
- **MUST:** Give each mutable business state and resource one authoritative
  owner. A snapshot is a read projection; it never becomes a second write path.
- **MUST:** Encode mutually exclusive async phases such as idle, pending,
  success, failed, cancelled, and offline with typed enums instead of related
  booleans or string status codes.
- **MUST:** Carry request revision/generation/key/scope through re-entrant async
  work. A weak entity check proves liveness, not relevance.
- **AVOID:** Parallel caches, event buses, or exit paths for the same state. The
  positive design is one write owner with explicit projections and messages.

## GPUI context and render

- **MUST:** Modify UI-observable state only inside a valid GPUI App, Context,
  AsyncApp, Entity, or Window update boundary.
- **MUST:** Background work captures Send inputs and returns immutable values;
  it does not mutate an Entity or Window directly.
- **MUST:** Render and Element paint read prepared state and construct visible
  elements. They do not start long-lived tasks, perform file/network/database/
  device/process I/O, sleep, receive, wait on long locks, synchronously read GPU
  results, or notify unconditionally.
- **SHOULD:** Route keyboard, menu, and pointer forms of the same user intent to
  one typed Action/handler. Use typed Event for child-to-owner communication and
  retain every Subscription in its lifecycle owner.
- **SHOULD:** Notify/emit only after semantic state change. Use child Entity,
  snapshot equality, revision, damage, or typed-region invalidation when update
  frequency or render breadth requires it.
- **SHOULD:** A keyboard-interactive component owns its FocusHandle/key context
  and restores a sensible focus target when a modal or palette closes.

## Async work and lifecycle

- **MUST:** Move filesystem, network, database, device, child-process, and heavy
  CPU work to the appropriate background executor/runtime/worker.
- **MUST:** Before foreground commit, verify owner/window existence and request
  identity. Discarded late results clean up any resource already created.
- **MUST:** Do not hold a synchronous lock across await. Do not join a worker
  that can block on read from the UI thread. Do not sleep or wait for task
  completion in an Action path.
- **MUST:** Every Task, Subscription, channel endpoint, worker/thread, process,
  socket, watcher, device, native handle, temporary artifact, and persistent
  write has a lifecycle ledger row with:

  | Resource | Owner | Start | Cancel/stale identity | Deadline | Join/flush | Error destination | Owner drop/late cleanup |
  |---|---|---|---|---|---|---|---|
  | concrete resource | Entity/App/module | trigger | protocol/key | bound or lower contract | policy | UI + redacted diagnostic | explicit result |

- **MUST:** Close button, close callback, menu/Action Quit, last-window exit, and
  normal process shutdown converge on one idempotent shutdown protocol when
  resources need confirmation, drain, flush, join, or cleanup.
- **SHOULD:** Cancellation defines request time, checkpoints, deadline, partial
  artifact cleanup, late-resource compensation, and completion confirmation.
  Dropping a UI Task handle alone is sufficient only for short, idempotent work
  with no external artifact.
- **AVOID:** Local long-lived detached work. Work intentionally outliving a View
  moves to an App/process owner with an error destination and exit policy.

## Channels, refresh, and capacity

- **MUST:** Classify each channel as replaceable state, reliable command, or
  high-frequency stream. Record producer, consumer, capacity, ordering, full,
  disconnect, retry/drop, shutdown, and sensitive-data behavior.
- **SHOULD:** Use watch/capacity-one/coalescing for replaceable state, a bounded
  request/result protocol for reliable commands, and frame/batch/revision gates
  for high-frequency streams.
- **AVOID:** Unbounded channels and ignored send results as defaults. A real-time
  producer that cannot block requires an ADR, observable soft/hard shedding,
  an explicit memory bound, and shutdown semantics.
- **MUST:** For potentially large data, declare independent acquisition,
  resident-memory, conversion/materialization, queue, layout/render, and cache
  bounds with overflow behavior. A virtual list only bounds visible rendering.
- **SHOULD:** Build only the visible range for large lists. Cache keys enumerate
  every visual dependency and tests cover reuse, invalidation, and stale data.

## Errors, recovery, and privacy

- **MUST:** Every user-triggered fallible operation reaches typed UI state with
  an applicable retry, cancel, retain, rollback, or dismiss action. Best-effort
  maintenance may use rate-limited diagnostics only when the product declares
  it disposable.
- **MUST:** Preserve typed error classification, source, and non-sensitive
  context through service layers. Map it to user language and recovery at the UI
  boundary rather than controlling behavior with formatted error strings.
- **MUST:** External input, I/O, channel closure, and platform failures do not
  use unwrap, expect, or panic. A proven internal invariant records its proof in
  code and a focused test.
- **MUST:** Logs, panic context, telemetry, debug state, and exported diagnostics
  exclude tokens, passwords, clipboard/document/database payloads, and other
  user content by default. Secret-bearing types use redacted Debug behavior.
- **SHOULD:** Optimistic UI state has an explicit rollback/retain policy and a
  test for persistence failure.

## Platform, unsafe, and UI dependencies

- **MUST:** Isolate Win32, COM, FFI, target dependencies, and unsafe code in a
  platform adapter. Upper layers receive capability or typed unsupported errors.
- **MUST:** A reviewed unsafe exception documents input validity, aliasing and
  lifetime, thread/apartment affinity, handle ownership, platform preconditions,
  failure cleanup, and the safe interface it exposes.
- **MUST:** Treat dependency capability, CI compilation, packaged artifact, and
  supported product tier as separate claims.
- **MUST:** Keep GPUI and gpui-component on the exact reviewed registry BOM and
  verify one package identity each. A git source is pinned by exact revision; a
  fork records upstream baseline, delta, compatibility evidence, owner, upgrade,
  and removal plan in an ADR.
- **SHOULD:** Isolate UI-stack upgrades from product changes, regenerate and
  inspect the lockfile, run the complete gate, and perform Windows runtime smoke.

## Tests and evidence

- **SHOULD:** Keep core policy testable without a real window, network, device,
  or filesystem. Add a fake/memory backend, clock, or executor when the real
  dependency varies and failure timing matters.
- **MUST:** For the changed chain, evaluate success, recoverable failure,
  cancellation, stale/late completion, channel full/disconnect, close/quit,
  migration, and platform fallback. Test applicable rows and state why other
  rows do not apply.
- **MUST:** Test stable module interfaces and observable behavior. Source-string
  assertions are not substitutes for behavior tests unless the string is itself
  the contract.
- **MUST:** Run focused checks before the canonical full gate. Record formatter,
  Clippy, tests, repository contracts, Windows build, manual smoke, packaging,
  performance, and accessibility separately.
- **MUST:** `Not run` is an evidence state. A workflow file, existing test,
  benchmark source, another platform, or narrower check cannot be reported as a
  current pass.

## Documentation, decisions, and completion

- **MUST:** Keep one canonical rule source. Root and scoped instructions are
  routing and local facts, not copies of this standard.
- **MUST:** Keep paths, commands, and local Markdown links current and checked.
  Documentation explains reasons and non-obvious contracts instead of caching
  discoverable source detail.
- **MUST:** Write or update an ADR for ownership, dependency direction,
  protocol/persistence, shutdown, platform tier, unsafe boundary, GPUI source/
  fork, or high-risk-pattern exceptions.
- **MUST:** Follow `docs/git-commit-policy.md`; each commit has one reason to
  revert and records direct evidence.

Before completion, account for every applicable item:

- current checkout, GPUI/component identity, scoped rules, and user changes;
- entry/owner/effect/background/guard/notify/render/error/shutdown chain;
- lifecycle ledger, channel semantics, capacity, cleanup, and privacy;
- success/failure/cancel/stale/close tests and focused/full checks;
- docs/ADR/commit updates and every dynamic check that remains unrun.
