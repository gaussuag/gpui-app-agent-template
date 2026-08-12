## Outcome and scope

Describe user-observable success and recoverable failure behavior. Link the task
specification for runtime or multi-module work and name explicit exclusions.

## Current chain and decisions

- Entry -> owner -> side effect -> background/foreground -> stale guard ->
  notify/render:
- Failure/recovery and close/quit paths:
- ADR added/updated, or not required with reason:

## Architecture and lifecycle

- [ ] Dependency direction remains `desktop -> app-ui -> app-core`.
- [ ] Changed Tasks/subscriptions/channels/workers/handles/artifacts have complete
      lifecycle rows and named stop/late-cleanup paths.
- [ ] Channel capacity, data bounds, error recovery, and privacy fields are
      recorded where applicable.
- [ ] UI-stack changes follow `docs/dependency-policy.md` and are isolated.

## Acceptance scenarios

| Scenario | Evidence or not-applicable reason |
|---|---|
| Primary success |  |
| Recoverable failure |  |
| Cancellation/stale completion |  |
| Channel full/disconnect |  |
| Owner/window close and App quit |  |
| Platform fallback |  |

## Automated test contract

- [ ] Every behavior change has tests in this change, or a concrete blocker and
      owned follow-up is recorded.
- [ ] The lowest stable seam and expected red failure are recorded in the task.
- [ ] GPUI behavior uses the explicit `app-ui` `test-support` suite; CI does not
      silently exclude it.

## Verification

| Gate | Exact command/action | Result and commit |
|---|---|---|
| Focused tests |  |  |
| `scripts/check.ps1` |  |  |
| Automated Windows smoke |  |  |
| Specialized manual Windows checks |  |  |
| Packaging/signing |  |  |
| Performance/accessibility |  |  |

List failures and unrun checks explicitly; do not infer them from workflow or
source presence.

## Commits and handoff

- Policy-compliant atomic commits:
- Remaining risks/follow-ups:
