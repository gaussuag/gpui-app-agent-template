# Agent task specification

Copy this template into the issue, task record, or change note for work that
changes runtime behavior or spans more than one module. Keep the record with the
task rather than committing a new copy for routine work. Apply
[the Agent development standard](agent-development-standard.md); this template
collects evidence and does not replace it.

Delete a conditional section only after recording why it is not applicable.

```markdown
## Outcome

What user-observable success and recoverable failure behavior must be true?

## Current facts

- Checkout/HEAD:
- Existing worktree changes and owner:
- Applicable root/scoped instructions:
- Rust toolchain:
- GPUI/gpui-component source, versions, and lock identities:
- Adjacent implementation and test seam:

## Scope

- Included modules/crates:
- Included platform tier:
- Data or persistent formats touched:
- Explicit exclusions:

## Current behavior chain

List current symbols and paths, not intended replacements.

| Branch | Entry | State/resource owner | Side effect and executor | Foreground return and stale guard | notify/render | Recovery | close/quit |
|---|---|---|---|---|---|---|---|
| Success |  |  |  |  |  |  |  |
| Recoverable failure |  |  |  |  |  |  |  |
| Cancel/stale/late |  |  |  |  |  |  |  |

## Invariants and decisions

- Architecture/state invariants:
- Lifecycle/cancellation invariants:
- Privacy/security invariants:
- Platform/dependency invariants:
- ADR required or not required, with reason:

## Lifecycle ledger

Required when a Task, Subscription, channel, worker, process, watcher, socket,
device, native handle, temporary artifact, or persistent write changes. Use the
full lifecycle template when more than two resources interact.

| Resource | Owner | Start | Cancel/stale identity | Deadline | Join/flush | Error destination | Owner drop/late cleanup |
|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |

## Channel and refresh contract

| Channel/signal | Message class | Producer/consumer | Capacity/order | Full/disconnect behavior | Batch/notify policy | Sensitive data | Shutdown |
|---|---|---|---|---|---|---|---|
|  | Replaceable state / reliable command / high-frequency stream |  |  |  |  |  |  |

## Data and performance bounds

| Layer | Expected/default | Hard or soft bound | Overflow/cancellation behavior | Evidence/measurement needed |
|---|---|---|---|---|
| Acquisition |  |  |  |  |
| Resident memory |  |  |  |  |
| Conversion/materialization |  |  |  |  |
| Event queue |  |  |  |  |
| Layout/render visible range |  |  |  |  |
| Cache |  |  |  |  |

## Error, recovery, and privacy

- Typed error/state:
- User recovery actions:
- Optimistic rollback/retain behavior:
- Redacted diagnostic fields:
- Prohibited log/persistence fields:

## Implementation and commits

1. Atomic slice:
2. Atomic slice:

Name dependency upgrades, refactors, generated changes, or migrations that must
remain separate.

## Acceptance matrix

| Scenario | Expected observable result | Test or direct evidence | Status/reason if not applicable |
|---|---|---|---|
| Primary success |  |  |  |
| Recoverable failure |  |  |  |
| Cancellation |  |  |  |
| Stale/late completion |  |  |  |
| Channel full/disconnect |  |  |  |
| Owner/window close |  |  |  |
| App quit/shutdown |  |  |  |
| Migration/rollback |  |  |  |
| Platform fallback |  |  |  |

## Verification evidence

| Gate | Exact command/action | Result and current commit | Artifact or failure summary |
|---|---|---|---|
| Focused tests |  |  |  |
| rustfmt |  |  |  |
| Clippy |  |  |  |
| Workspace tests |  |  |  |
| Architecture/Agent contracts |  |  |  |
| Windows MSVC build |  |  |  |
| Manual Windows smoke |  |  |  |
| Packaging/signing |  |  |  |
| Performance/accessibility |  |  |  |

## Handoff

- Commits:
- Decisions and lifecycle changes:
- Unrun checks and reasons:
- Remaining risks or follow-up tasks:
```

The task is complete only when every applicable acceptance item has direct
current-state evidence. `Not run` is a valid report, not a passing result.
