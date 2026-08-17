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
rule. The generator derives the verification profile and required checks from
policy, fixes `task_start_revision` to current `HEAD`, refuses overwrite, and
validates the result.

```powershell
.\scripts\new-change.ps1 `
  -ChangeId EC-EXAMPLE-001 `
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

## Validate the declared surface

Run these public entry points with the same ChangeSpec:

```powershell
.\scripts\check-policy.ps1
.\scripts\check-change-spec.ps1 -ChangeSpecPath <path>
.\scripts\check-scope.ps1 -ChangeSpecPath <path>
.\scripts\check-protected-paths.ps1 -ChangeSpecPath <path>
```

The scope check compares the fixed task-start commit through `HEAD`, then adds
staged, unstaged, and untracked paths. It uses NUL-safe Git output, includes both
rename and copy endpoints, and matches repository paths case-insensitively for
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

The validators hard-reject malformed or unknown data, unavailable task-start
commits, draft execution, lane/profile mismatches, missing or extra required
checks, invalid persistence locations, scope or budget violations, undeclared
crates/dependency impact, Bot widening, and protected-path changes from an
unauthorized lane.

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
