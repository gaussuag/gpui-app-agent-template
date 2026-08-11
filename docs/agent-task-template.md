# Agent task specification

Copy this section into an issue or task for non-trivial work.

```markdown
## Outcome
What user-observable behavior must be true?

## Scope
Which modules and platform tier are included?

## Invariants
Which architecture, lifecycle, data, privacy, and failure rules must remain true?

## Acceptance evidence
- [ ] Primary success behavior
- [ ] Recoverable failure behavior
- [ ] Cancellation/close behavior
- [ ] State or adapter tests
- [ ] scripts/check.ps1
- [ ] Manual Windows smoke, if runtime behavior changed

## Explicit exclusions
Which adjacent upgrades, refactors, and platform work are separate tasks?
```

An agent completes the task only when every acceptance item has direct evidence.
An unrun check is reported as unrun, not inferred from source or another check.
