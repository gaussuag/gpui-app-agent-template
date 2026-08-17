# ADR 0004: Narrow executable change contracts

- Status: accepted
- Date: 2026-08-17
- Owners: repository owners
- Scope: repository governance policy and ChangeSpec protocol

## Decision

The repository adds a narrow machine policy and closed ChangeSpec format for
change authorization. Full and governance changes commit a ChangeSpec; focused
and bot changes use the same contract as a temporary file outside the worktree.
The policy owns only deterministic lane, profile, protected-path, and budget
facts. Existing specialist scripts retain architecture, dependency, product,
test, Windows, and full-gate authority.

`scripts/check.ps1` remains the single complete quality oracle. Change-contract
checks answer whether a change is authorized; they do not duplicate Rust,
GPUI, Windows, product, or smoke validation.

## Current facts

The repository already has scoped Agent instructions, focused/full lanes, a
full task record, architecture and dependency checks, policy self-tests, a
Windows quality gate, and a generated-product fixture. It has no deterministic
comparison between authorized scope and the actual Git diff, no protected-path
classification, and no machine representation of expansion budgets.

The current hosted workflow checks out the candidate revision before running
repository scripts. Core is therefore local/candidate policy enforcement, not a
trusted target-branch verdict. Remote trust controls require a separate owner
decision and delivery.

## Invariants and forces

- Correctness and product invariants: `desktop -> app-ui -> app-core` and every
  product/runtime owner remain unchanged.
- Lifecycle and shutdown requirements: no runtime resource or shutdown path is
  introduced.
- Error, recovery, and privacy requirements: validators fail closed with paths
  and rule names; policy inputs contain no credentials or user data.
- Capacity/performance requirements: checks operate on bounded repository data
  and finite Git output without network access.
- Compatibility and dependency constraints: PowerShell 7's `Test-Json` validates
  the schemas; no Rust crate or third-party dependency is added.

## Options considered

### Keep documentation-only authorization

- Benefits: no new code or format.
- Costs and failure modes: agents can expand scope or modify acceptance controls
  without deterministic detection.
- Rejected because: it leaves the failure modes targeted by v0.2 unresolved.

### Install the complete research overlay

- Benefits: includes a broad Trust, Evidence, Eval, and Governance design.
- Costs and failure modes: duplicates current architecture facts, adds premature
  control planes, and its PowerShell reference is not executable as delivered.
- Rejected because: the repository needs a smaller, current-source adaptation.

### Add the narrow Core contract

- Benefits: closes the authorization gap while reusing every existing quality
  owner and keeping focused work lightweight.
- Costs and failure modes: adds a small policy/schema surface and remains
  candidate-local until Trust is implemented.
- Selected because: it is the smallest reversible control that addresses the
  observed gaps.

## Consequences

- New owner and dependency relationships: `.agentinfra/policy.json` owns
  deterministic governance data; PowerShell validators consume it. Product
  crates gain no dependency.
- Migration/compatibility effects: existing Full records gain a committed JSON
  companion; Focused records remain compact and receive a temporary projection.
- New operational or maintenance cost: policy/schema changes use the governance
  lane, direct positive/negative fixtures, and owner review.
- Known limitations: Core cannot claim `ci-trusted`, activate platform controls,
  or prove semantic declarations such as architecture intent.

## Validation and observability

- Focused tests and fault injection: schema, command rejection, path, budget,
  protected-path, bot, and result-status fixtures.
- Repository/CI gates: existing policy tests and `scripts/check.ps1`.
- Platform smoke or runtime measurement: existing Windows gate remains the
  applicable runtime evidence; the governance scripts add no runtime behavior.
- Logging/metrics without sensitive payloads: validators report rule and path;
  no environment or command payload is persisted.

## Rollback, upgrade, or removal

Each control is delivered in an independently revertible local commit. Removing
Core deletes `.agentinfra` and its entry scripts, removes the short workflow
routes, and restores the prior policy-test integration. A future version changes
the JSON contract through a new schema version and migration decision rather
than silently reinterpreting committed records.

## Related evidence

- Task/issue: owner-authorized v0.2 Core governance construction
- Source symbols and tests: `scripts/check-policy.ps1`,
  `scripts/check-change-spec.ps1`, and `scripts/test-executable-constitution.ps1`
- Dependency/fork baseline: no dependency or lockfile change
- Superseded ADRs: none
