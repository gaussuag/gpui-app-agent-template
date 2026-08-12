# ADR 0002: Application-owned last-window exit

- Status: accepted
- Date: 2026-08-12
- Owners: repository and `app-ui` owners
- Scope: GPUI application lifecycle and Windows Tier 1 smoke

## Decision

`app-ui` registers one application-lifetime `on_window_closed` observer. After
GPUI removes a window, the observer checks the authoritative application window
collection and calls `cx.quit()` only when no windows remain.

An App-global `ApplicationLifecycle` owner retains the returned `Subscription`.
The baseline does not detach the subscription or add a source-risk exception.
The Windows native smoke separately verifies the finite first-frame self-check
and a normal process receiving a standard main-window close request.

## Current facts

- Process startup enters `desktop::main`, which delegates all GPUI lifecycle
  behavior to `app_ui::run` or finite `app_ui::run_smoke`.
- GPUI 0.2.2 invokes `on_window_closed` observers after removing the closed
  window from its application collection.
- The locked GPUI 0.2.2 Windows backend currently posts a quit message after its
  final raw window handle closes, but that is an upstream platform behavior, not
  an application-owned policy.
- The previous finite smoke called `cx.quit()` immediately after
  `window.remove_window()`, so it could not exercise an application-level
  last-window observer.

## Invariants and forces

- `app-ui` remains the sole owner of GPUI Application/window setup.
- Closing one of several windows does not terminate the application.
- The observer and quit request run on the GPUI foreground context and perform
  no blocking work or external I/O.
- Every `Subscription` has a named owner and drop path.
- There is currently no application data or external resource to drain, flush,
  or join. The first such resource must extend this policy into a shared,
  idempotent shutdown coordinator.

## Options considered

### Application-owned last-window observer

- Benefits: makes the exit rule visible, multi-window safe, directly testable,
  and independent of implicit backend behavior.
- Costs and failure modes: adds one application-lifetime subscription and a
  small amount of startup wiring.
- Selected because the ownership and maintenance cost are proportionate to a
  Windows desktop template's process-exit contract.

### Depend on the GPUI Windows backend

- Benefits: no application code.
- Costs and failure modes: the policy is hidden in a pre-1.0 dependency and the
  application cannot evolve one explicit shutdown path around it.
- Rejected because Tier 1 behavior is a repository-owned promise.

### Quit after every window close

- Benefits: simplest callback.
- Costs and failure modes: closing a secondary window would terminate a future
  multi-window application.
- Rejected because the intended boundary is the last application window.

## Consequences

- `ApplicationLifecycle` owns the observer until App shutdown, when dropping the
  owner unsubscribes it.
- Interactive close and the finite smoke converge on the same application quit
  request; startup failure retains its direct error-and-quit path.
- No new thread, timer, channel, Win32 binding, unsafe code, or dependency is
  introduced.
- GPUI's current platform-level final-window behavior may also request process
  exit; the application callback remains the authoritative project policy.

## Validation and observability

- A GPUI headless test opens two windows, proves the first close does not request
  quit, and proves the final close does.
- `scripts/smoke.ps1` requires the finite first-frame/Action process to exit via
  window removal and the shared policy.
- The same script launches the normal executable, waits for its main window,
  requests native closure, and enforces a 15-second process-exit deadline.
- `scripts/check.ps1` runs the headless test, source-risk policy, Windows MSVC
  build, and both native smoke phases.

## Rollback, upgrade, or removal

Supersede this ADR before adopting a resident-without-windows process model or a
different shutdown coordinator. A rollback removes the App-global observer and
its tests together; it must not silently restore dependence on implicit GPUI
backend behavior while Windows remains Tier 1.

## Related evidence

- Source symbols: `install_last_window_quit_policy`, `ApplicationLifecycle`,
  `run_with_mode`.
- Tests: `last_window_policy_requests_quit_only_after_the_final_window_closes`
  and `scripts/smoke.ps1`.
- Dependency baseline: GPUI 0.2.2 and gpui-component 0.5.1 from ADR 0001.
