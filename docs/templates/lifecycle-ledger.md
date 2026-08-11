# Lifecycle ledger template

Use this template when a change introduces or connects multiple asynchronous or
external resources. A small change may keep the same fields directly in its task
specification and update the current inventory in `docs/architecture.md`.

## Product semantics

- Resource-owning feature:
- Authoritative state owner:
- Work allowed to outlive a window:
- Work allowed to outlive the application:
- Data that must flush before exit:
- Maximum user-visible shutdown wait:

## Resources

| Resource | Owner | Start trigger | Cancel/stale identity | Deadline | Join/flush | Error destination | Owner drop/late cleanup |
|---|---|---|---|---|---|---|---|
| Task/Subscription/channel/worker/process/socket/device/handle/artifact/write | Entity/App/module | Action/init | token/revision/key/protocol | explicit duration or lower contract | wait/discard/flush | recovery UI + redacted diagnostic | exact cleanup |

## Channels

| Name | Message class | Producer | Consumer | Capacity/order | Full behavior | Disconnect behavior | Batch/notify | Sensitive data |
|---|---|---|---|---|---|---|---|---|
|  | Replaceable state / reliable command / high-frequency stream |  |  |  |  |  |  |  |

## Shutdown convergence

| Entry | Shared transition | Confirmation | Stop new work | Drain/flush/join | Deadline result | Final state |
|---|---|---|---|---|---|---|
| Window close |  |  |  |  |  |  |
| Menu/Action Quit |  |  |  |  |  |  |
| Last window |  |  |  |  |  |  |
| Owner Drop |  |  |  |  |  |  |

## Late completion and partial artifacts

- Result arriving after cancellation:
- Resource created after owner replacement:
- Temporary/partial file cleanup:
- Process/socket/device cleanup:
- Diagnostic correlation and redaction:

## Deterministic tests

- [ ] owner disappears before completion;
- [ ] newer revision wins;
- [ ] cancellation at every checkpoint;
- [ ] channel full and disconnected;
- [ ] shutdown invoked twice;
- [ ] deadline expires;
- [ ] partial artifact cleanup fails;
- [ ] recovery state remains actionable.
