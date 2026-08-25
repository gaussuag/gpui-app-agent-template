# ADR 0006: Accept executable constitution residuals

- Status: accepted
- Date: 2026-08-25
- Owners: repository owners
- Scope: executable constitution Core review disposition

## Decision

The repository accepts the current behavior behind review findings F-001,
F-003, F-005, F-006, F-007, F-008, F-010, and F-011. They are current Core
limitations, not planned repair work.

The decision adds no gate, detector, fixture, metric, schema field, reporting
format, or proactive adversarial defense. Existing task evidence remains the
only observation path. If an ordinary Code Agent task encounters one of these
conditions and it produces concrete impact, that occurrence is reported through
the existing task handoff and the Owner reassesses priority from that evidence.
Synthetic adversarial input or fault injection alone does not reopen the
decision.

This disposition supersedes the remediation expectation attached to those
finding IDs. It does not erase the review evidence or claim that the underlying
behavior changed.

## Current facts

| Finding | Accepted current behavior | Reason for no repair |
|---|---|---|
| F-001 | Scope rejects the documented literal root catch-alls but does not classify every semantically equivalent wildcard expression. | The remaining forms require deliberately constructed scope input; broader glob-language defense has no observed ordinary-task value. |
| F-003 | ChangeSpec retains the narrow closed schema, current string validation, ADR-prefix check, `owner_decisions` blocking convention, and task-template acceptance matrix. | Additional Oracle, open-question, observation, stable-rule-ID, whitespace, or ADR-existence machinery would expand or duplicate the selected Core contract without an observed task failure. |
| F-005 | `ActualBudgets` includes two values projected from declared architecture flags rather than independent semantic source measurement. | Core already states that it cannot prove semantic architecture declarations; adding semantic detection or a result-shape migration is not justified by current use. |
| F-006 | Bot scope authorizes policy-listed Cargo paths and a dependency declaration without parsing which TOML keys changed. | Hosted Bot activation is deferred; a Cargo semantic-diff subsystem would be premature until ordinary automated dependency use demonstrates the need. |
| F-007 | The repository uses the narrow Core selected by ADR 0004 rather than the broader research overlay. | Existing specialist contracts remain authoritative, and duplicating them into a larger Constitution/Policy surface would increase maintenance without current product value. |
| F-008 | Product initialization retains its existing rollback implementation without a dedicated post-policy-write fault-injection fixture. | The normal generated-product path is covered; no partial-initialization failure has been observed. |
| F-010 | The pull-request template repeats the current result-status vocabulary instead of replacing it with only a canonical link. | The vocabulary is small and stable, and no actual drift has occurred. |
| F-011 | Historical commits retain their existing Evidence wording and the registry correction remains a refactor commit. | Current behavior is unaffected, and rewriting local history would add risk without delivery value. |

An ordinary Code Agent task means the documented lane and delivery workflow
using non-adversarial task data. A future Owner decision to activate hosted Bot
automation or adopt the broader governance overlay is a scope change and may
reconsider the applicable row without waiting for an incident.

## Invariants and forces

- Correctness and product invariants: product runtime, crate boundaries, and
  repository quality gates remain unchanged.
- Lifecycle and shutdown requirements: no runtime resource or lifecycle path is
  involved.
- Error, recovery, and privacy requirements: existing task failures and handoff
  evidence remain the reporting path; no new data is collected.
- Capacity/performance requirements: no runtime or validation work is added.
- Compatibility and dependency constraints: policy/schema formats, committed
  ChangeSpecs, tests, dependencies, and Git history remain unchanged.

## Options considered

### Repair every reviewed condition

- Benefits: satisfies the strict external review rubric without accepted
  residuals.
- Costs and failure modes: expands schemas and validation semantics, adds
  adversarial and fault-injection fixtures, creates duplicate governance
  surfaces, and increases ongoing maintenance.
- Rejected because: there is no current ordinary-workflow evidence that the
  combined cost improves delivery.

### Accept the current Core and reconsider from real use

- Benefits: preserves the small executable contract and directs effort toward
  observed Code Agent failures.
- Costs and failure modes: the accepted conditions remain possible and a strict
  audit that ignores this Owner decision can report them again.
- Selected because: it matches the intended risk and maintenance budget.

## Consequences

- New owner and dependency relationships: none.
- Migration/compatibility effects: none.
- New operational or maintenance cost: one decision record and one contract
  pointer; no recurring check or report.
- Known limitations: every accepted row remains true until later implementation
  or a superseding Owner decision changes it.

## Validation and observability

- Focused tests and fault injection: not added; this decision changes no
  behavior.
- Repository/CI gates: existing documentation and repository checks remain
  applicable without new cases.
- Platform smoke or runtime measurement: not applicable to a decision-only
  documentation change.
- Logging/metrics without sensitive payloads: no logging or metrics are added.

## Rollback, upgrade, or removal

Supersede this ADR when current ordinary-task evidence justifies repair or when
the Owner authorizes a broader governance stage. Reverting the documentation
commit removes the disposition without changing runtime or validator behavior.

## Related evidence

- Task/issue: Owner disposition of the 2026-08-24 independent Core review
- Change contract: `.agentinfra/changes/EC-ACCEPT-CORE-RESIDUALS.json`
- Related decisions: [ADR 0004](0004-executable-constitution-core.md) and
  [ADR 0005](0005-authoritative-change-contract-resolution.md)
- Dependency/fork baseline: no dependency or lockfile change
- Superseded ADRs: none
