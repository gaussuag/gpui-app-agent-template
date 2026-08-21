# ADR 0005: Authoritative change contract resolution

- Status: accepted
- Date: 2026-08-21
- Owners: repository owners
- Scope: executable ChangeSpec protocol and repository acceptance controls

## Decision

Repository acceptance resolves one change contract from independent task context
and Git provenance before applying document, scope, or protected-path rules.
The task runner captures an effective task-start revision before any repository
edit and supplies it as a mandatory input. A ChangeSpec's
`task_start_revision` is only a declaration that must equal that independent
value; it never selects the Git comparison range.

Full and governance changes resolve their one authoritative committed
ChangeSpec automatically from the effective task-start through the requested
head. The resolver proves that the Spec was first added by the first task
commit, remains tracked and present at the head, has stable identity and task
start, and has no competing or uncommitted ChangeSpec state. A caller-provided
path can assert the resolved path but cannot select a different contract.

Focused and bot changes continue to use one runner-provided repository-external
transient Spec. Their declared task start must match the independent input, and
their repository range cannot contain a committed-lifecycle Spec candidate.

The resolver derives `authoring` or `final` from Git and Spec state. Draft,
untracked, staged-only, or locally modified Specs can provide authoring
feedback only when explicitly allowed. Final acceptance requires a ready,
committed, clean contract. Governance results remain `review_required` in both
local development and final local validation.

## Current facts

The v0.2 Core validators currently let the ChangeSpec field select the Git diff
start and let the caller select the ChangeSpec path. Their committed-lifecycle
check proves only that a file is located under `.agentinfra/changes/`; it does
not prove that Git tracks the file, that the file is present at the requested
head, that it belongs to the current task range, or that it is unique. Scope
and protected-path checks therefore consume self-certified range data.

The task runner can capture the actual starting commit before edits. Git
provides commit ancestry, per-commit name-status history, tracked state, head
content, and staged, unstaged, and untracked state without a new dependency or
remote service.

## Invariants and forces

- Correctness and product invariants: product crates and the
  `desktop -> app-ui -> app-core` direction remain unchanged; all public
  governance entry points consume one resolver result.
- Lifecycle and shutdown requirements: acceptance performs bounded local Git
  queries only; test repositories are temporary resources owned and removed by
  their individual test cases.
- Error, recovery, and privacy requirements: missing, unavailable,
  non-ancestor, mismatched, ambiguous, or dirty provenance fails closed with an
  actionable reason; no credentials or user payloads are recorded.
- Capacity/performance requirements: resolution scans finite repository Git
  output for the requested task range and never uses the network.
- Compatibility and dependency constraints: existing JSON schema version 0.2
  remains valid, and no Rust or third-party dependency changes.

## Options considered

### Keep the ChangeSpec declaration authoritative

- Benefits: no public command change and fewer Git queries.
- Costs and failure modes: a late-created or edited Spec can move the range
  forward and hide ordinary or protected changes.
- Rejected because: data under validation cannot safely define its own evidence
  boundary.

### Require callers to provide both task start and an authoritative Spec path

- Benefits: detects a moved start while retaining current path-based entry
  points.
- Costs and failure modes: duplicate, stale, untracked, or more permissive
  Specs remain caller-selectable.
- Rejected because: it fixes range self-certification but leaves contract
  identity self-selection.

### Resolve effective start and committed Spec from task context and Git

- Benefits: one resolver owns range, identity, provenance, lifecycle, and
  ambiguity rules for every acceptance adapter.
- Costs and failure modes: final checks require the independently captured
  task-start value and additional deterministic Git queries.
- Selected because: it closes F-002 and F-004 together without adding hosted
  infrastructure or a second quality gate.

## Consequences

- New owner and dependency relationships: `Resolve-ECChangeContract` in the
  executable-constitution module owns repository-level contract resolution;
  public validation scripts adapt its immutable result.
- Migration/compatibility effects: callers must preserve and pass the task
  start captured before edits. Full/governance callers no longer choose a Spec;
  focused/bot callers still provide their external temporary Spec.
- New operational or maintenance cost: policy fixtures must construct real Git
  provenance and exercise authoring and final states independently.
- Known limitations: a candidate-local runner can still modify candidate code
  and cannot establish Base-trusted or cryptographic evidence. Hosted Trust,
  Evidence Bundles, CODEOWNERS, Rulesets, and platform settings remain outside
  this decision.

## Validation and observability

- Focused tests and fault injection: isolated Git fixtures cover mismatched and
  invalid starts, retroactive ordinary/protected changes, committed and
  transient lifecycle, ambiguity, rename/copy endpoints, dirty Specs, and
  later valid updates.
- Repository/CI gates: direct executable-constitution suites,
  `scripts/test-policy-scripts.ps1`, and the existing `scripts/check.ps1` full
  quality oracle.
- Platform smoke or runtime measurement: the existing Windows smoke remains
  required by the full gate; this decision changes no product runtime path.
- Logging/metrics without sensitive payloads: validators report revision,
  lifecycle rule, and repository-relative offending path only.

## Rollback, upgrade, or removal

Reverting the resolver contract, its public adapters, tests, and documentation
as one behavior slice restores the earlier path-based semantics. That rollback
also restores the F-002/F-004 bypasses and therefore requires repository-owner
review. A future hosted trust stage must extend this local candidate contract in
a separate decision and separate platform-authorized change.

## Related evidence

- Task/issue: `EC-F002-F004-F009-REPAIR`
- Source symbols and tests: `Resolve-ECChangeContract`, the three public
  acceptance scripts, and `scripts/test-executable-constitution.ps1`
- Dependency/fork baseline: no Cargo, dependency, workflow, or remote setting
  change
- Superseded ADRs: none; this decision narrows ADR 0004's local Core semantics
