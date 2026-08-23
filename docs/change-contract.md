# Executable change contract

Every repository change is bounded by a machine-readable ChangeSpec before
implementation. This document owns the human workflow for that contract;
`.agentinfra/policy.json` owns lane, profile, protected-path, budget-indicator,
Bot, and result-status data. The JSON schemas own accepted fields and reject
unknown fields. They do not execute commands from policy or ChangeSpec input.

Current source, Git state, scoped `AGENTS.md`, specialist architecture and
platform contracts, and `Cargo.lock` remain authoritative for implementation
facts. A ChangeSpec records authorization and expected evidence; it is not proof
that a check ran or passed.

## Choose and persist the lane

| Lane | Boundary | ChangeSpec lifecycle | Completion outcome |
|---|---|---|---|
| Read-only | No repository files change | No ChangeSpec or commit | Evidence-backed report |
| Focused | One owner/module; no dependency, lifecycle, platform, protocol, privacy, unsafe, ownership-direction, or public-layer change | Generate outside the repository; all expansion budgets are zero | Eligible only after its required checks pass |
| Full | Multiple modules or any Full-change trigger in the Agent workflow | Commit under `.agentinfra/changes/`; use the full task specification | Eligible only after its repository-profile checks pass |
| Governance | Policy, Agent authority, acceptance controls, protected paths, or trust-control design | Commit under `.agentinfra/changes/`; use the full task specification | Always `review_required`, including when every check passes |
| Bot | Declared dependency update only | Generate outside the repository; scope is the intersection of ChangeSpec and policy Bot paths | Eligible only after its required checks pass |

Generate a draft with `scripts/new-change.ps1`. Full and Governance drafts use
the committed directory automatically; Focused and Bot drafts use the system
temporary directory. Explicit output paths cannot violate that persistence
rule. Before any edit, the task runner records the current commit and passes it
to the generator as `TaskStartRevision`. The generator verifies that this full
commit id exists and is an ancestor of `HEAD`, derives the verification profile
and required checks from policy, refuses overwrite, and validates the result.
It never substitutes the current `HEAD` for a missing task-start input.

```powershell
$taskStart = (git rev-parse HEAD).Trim()
.\scripts\new-change.ps1 `
  -ChangeId EC-EXAMPLE-001 `
  -TaskStartRevision $taskStart `
  -Title "Bound the requested change" `
  -Lane full `
  -ChangeKind feature `
  -Outcome "State the observable result." `
  -Recovery "State the recovery behavior." `
  -AllowedPaths @("crates/app-core/**") `
  -Exclusions @("No UI, platform, dependency, or remote changes.")
```

Edit the closed data fields, resolve blocking owner decisions, and change
`state` from `draft` to `ready` before implementation. A ready Full or
Governance ChangeSpec is review history and stays committed. Routine Focused
and Bot specs never enter the repository.

The task-start value kept by the runner is the effective task start. The
ChangeSpec field is only a declared value that must match it exactly. Final
Full/Governance validation discovers the one task ChangeSpec from Git instead
of accepting a caller-selected path. The Spec must be added by the first task
commit, remain tracked and present at `HEAD`, retain its original change ID and
task start, and have no competing or uncommitted ChangeSpec state. Later commits
may update that same file without changing its identity.

Git and Spec state determine the lifecycle. Draft, untracked, staged-only, or
locally modified committed-lane Specs are `authoring` and require
`-AllowDraft`; they cannot produce a final outcome. A ready, clean Spec with
valid committed provenance is `final`. A ready Focused/Bot Spec outside the
repository is final only when its task start matches the runner input and the
repository range contains no committed-lifecycle Spec candidate.

## Validate the declared surface

Run these public entry points with the task-start value captured before edits.
Full and Governance final checks resolve the committed Spec automatically:

```powershell
.\scripts\check-policy.ps1
.\scripts\check-change-spec.ps1 -TaskStartRevision $taskStart
.\scripts\check-scope.ps1 -TaskStartRevision $taskStart
.\scripts\check-protected-paths.ps1 -TaskStartRevision $taskStart
```

Focused and Bot checks also pass their runner-owned external path with
`-ChangeSpecPath`. For Full/Governance, that parameter is optional and only
asserts equality with the automatically resolved path; it never selects the
contract.

The shared resolver validates that the effective task start exists and is an
ancestor of the requested head. It resolves both the requested head and the
current checkout `HEAD` to full commit IDs and rejects them unless they are the
same commit, before consulting the live Spec, index, working tree, or untracked
state. Both `HEAD` and the full ID of the current commit are valid inputs. To
validate a historical revision, check out that revision first and run the local
acceptance commands from that checkout.

After that guard, the resolver inspects the final net diff, per-commit
name-status history, staged, unstaged, and untracked state, including both
rename and copy endpoints. Scope and protected-path checks then use only the
resolver's effective task start. Paths remain NUL-safe and case-insensitive for
Windows. Git copy detection remains a similarity heuristic, so both reported
endpoints must be authorized.

Forbidden patterns win over allowed patterns. Paths cannot escape the
repository, use a drive/UNC/device form, or use a root-wide catch-all. Every
changed crate must appear in `expected_crates`. Observable additions and
manifest, workflow, protected-file, unsafe-boundary, and public-layer indicators
must remain at or below their declared budgets. A changed dependency manifest
also requires the dependency-impact flag.

Bot scope is checked against immutable policy before its own allowed paths;
the spec may narrow that set but cannot widen it. Dependabot-style commit
subjects are accepted only through the explicit local `-Bot` option. Hosted
activation is not part of Core.

## Hard rejection and review

The validators hard-reject malformed or unknown data, missing or unavailable
independent task starts, non-ancestor heads, declared/effective start mismatch,
ambiguous or wrong-range Specs, invalid committed provenance, final authoring
state, lane/profile mismatches, missing or extra required checks, invalid
persistence locations, scope or budget violations, undeclared crates/dependency
impact, Bot widening, and protected-path changes from an unauthorized lane.

Governance is different from rejection: an authorized protected change can be
classified, tested, and committed locally, but its result remains
`review_required`. Green checks cannot promote it to `passed`.

Only the literal policy status `passed` satisfies a required check. `failed`,
`skipped`, `not_run`, `environment_failure`, `policy_rejected`, and
`review_required` are non-passing. Missing required results resolve to
`not_run`; never infer success from source, a workflow file, or a narrower gate.

## Evidence and delivery

The Core does not persist runner-generated Evidence objects. Record exact
commands and statuses in task context, commit messages, the PR template, and
the final Quality/History/Worktree handoff. Run the ChangeSpec validators while
each slice evolves, then run `scripts/check.ps1` and the commit-range check from
the Agent workflow against the final local history.

Core authorizes no push, merge, release, history rewrite, credential change, or
remote repository setting change. Structured Evidence, CODEOWNERS, Branch
Rulesets, hosted Required Checks, Eval Replay, and hosted Bot activation belong
to a separately authorized Trust stage and separate GitHub-platform commits.
