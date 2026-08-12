# Agent workflow

This is the ordered recipe for repository change tasks. The normative rules are
in [the Agent development standard](agent-development-standard.md); this file
defines when work may advance to the next step.

## Choose the task lane

| Lane | Use when | Required record and delivery |
|---|---|---|
| Read-only | Explain, diagnose, or review without modifying repository files | Establish current facts, report evidence and unverified claims, and do not commit. Stop before the change workflow below. |
| Focused change | One owner and module; does not change async/resource lifecycle, platform behavior, dependencies, protocol/persistence, privacy, or an unsafe boundary | Record outcome, owner, stable test seam, atomic slice(s), exact evidence, and exclusions in task context. Follow every applicable step below. |
| Full change | Multiple modules, or any async/resource lifecycle, platform, dependency, protocol/persistence, privacy, or unsafe-boundary change | Use [the full task specification](agent-task-template.md) and follow every step below. |

If investigation turns a read-only task into a change, or a focused change
crosses a full-change boundary, reclassify it before editing further. The lane
changes evidence depth, not architecture, test, commit, or permission standards.

## 1. Establish current facts

1. Read the root and nearest scoped `AGENTS.md`.
2. Record `git rev-parse HEAD` as the task-start commit. Inspect `git status`
   and separate pre-existing changes from task changes.
3. Read the target manifest, crate root, implementation, adjacent tests, and CI
   entry used for that area.
4. Read `rust-toolchain.toml`, root UI dependencies, and the relevant lockfile
   package identities before using a GPUI API.
5. Load the conditional architecture, dependency, Windows, or
   [decision records](decisions/README.md) named by the root contract.

**Complete when:** task notes identify the task-start commit, checkout facts,
applicable scoped rules, current dependency lineage, existing user changes, and
authoritative files. Old chat or documentation is not the only evidence for any
claim.

## 2. Reconstruct the current behavior

Trace exact symbols and files for every applicable branch:

```text
input/Action/OS event
  -> state owner
  -> validation and immediate transition
  -> requested side effect
  -> background executor/runtime/worker
  -> immutable result plus request identity
  -> GPUI foreground update
  -> owner/stale check
  -> emit/notify
  -> render projection
```

Add the failure/recovery, cancellation/late-result, and close/Quit/Drop paths.
Inventory Tasks, Subscriptions, channels, workers, processes, native handles,
temporary artifacts, persistent writes, and sensitive data touched by the chain.

**Complete when:** each entry, write owner, side effect, foreground return,
failure destination, and exit path is accounted for, or explicitly marked not
applicable with current-source evidence.

## 3. Bound the change

For a focused change, record the compact lane fields in task context. For a full
change, use [the task specification](agent-task-template.md) to record:

- user-observable outcome and recovery behavior;
- included modules/platform tier and explicit exclusions;
- invariants and decisions that remain true;
- lifecycle, channel, capacity, privacy, and test evidence as applicable;
- dependency-safe atomic implementation and commit slices, each coherent without
  a later slice and carrying one reason to revert.

For each changed contract, name the stable observation seam, lowest test layer,
expected failing test, applicable scenarios, and why a higher layer is or is not
needed. Follow [the automated testing standard](testing-standard.md); behavior
and its automated test remain one change.

Find an adjacent pattern and test seam before creating a new abstraction. Add a
service trait or adapter seam only when a real production dependency varies and
a second implementation, normally a deterministic test adapter, is required.

Write or update an [ADR](decisions/README.md) before changing state/resource
ownership, dependency direction, protocol/persistence format, shutdown
semantics, platform tier, unsafe boundary, GPUI source/fork, or a
high-risk-pattern exception.

**Complete when:** the requested result, excluded work, invariants, implementation
slices, and direct acceptance evidence are checkable before code changes begin.

## 4. Implement the next slice through owners

1. Select one planned atomic slice. Keep later slices out of the working diff.
2. Make state transitions in the authoritative module.
3. Return side-effect requests as values and interpret them at the adapter seam.
4. Keep external latency off the GPUI foreground path.
5. Return small immutable results and commit them once on the foreground context.
6. Check entity/window existence and request revision before committing.
7. Notify only for semantic state changes; render only the prepared projection.
8. Add the failing test at the planned stable seam, then implement the behavior.
9. Update lifecycle/channel/capacity records and tests with the behavior.

Keep unrelated refactors, dependency upgrades, generated churn, and product
ideas outside the task. Preserve pre-existing changes and stage explicit paths.

**Complete when:** the selected slice returns every changed branch to its
authoritative owner, has an error and lifecycle outcome, and its working diff
contains only that slice's direct implementation, tests, and documentation.

## 5. Prove and commit the slice

1. Run the focused command named by the closest scoped instructions. Use the
   applicable `scripts/test.ps1` layer when Rust behavior changes.
2. Exercise success, recoverable failure, cancellation/stale completion, and
   close/quit cases that apply to the change.
3. Inspect `git status`, stage only the slice's explicit paths, and review
   `git diff --cached`.
4. Confirm the staged state is coherent without a later slice, has one reason to
   revert, and includes its direct tests and documentation.
5. Create the local commit under [the Git commit policy](git-commit-policy.md),
   including Why, What, and the focused Evidence collected for this slice.
6. Return to workflow step 4 and repeat this proof-and-commit step for every
   planned slice. If implementation reveals a new revert reason or dependency,
   update the plan before starting that slice.

Record exact commands and outcomes. Report a check as `not run` with its reason
when environment or authorization prevents it; never infer a pass from source,
another platform, a workflow file, or a narrower command.

**Complete when:** every planned slice has focused evidence and a policy-compliant
local commit, and no task-owned implementation remains only in the working tree.

## 6. Verify the final commit state and hand off

1. Inspect `git status`. Run `scripts/check.ps1` using the pinned toolchain
   against the final commit state. When preserved pre-existing changes would
   contaminate HEAD-only evidence, use a safe isolated detached worktree if the
   environment permits; otherwise report the result as mixed-checkout evidence.
   Never stash, reset, or rewrite user changes to manufacture a clean checkout.
2. Perform specialized manual Windows checks where applicable; the automated
   Windows smoke remains part of the full gate.
3. If the final gate finds a defect, return to step 3, plan a corrective slice
   with one revert reason, commit it, and rerun this step. Do not hide unrelated
   corrections in a generic cleanup commit.
4. Run `scripts/check-commits.ps1 "<task-start>..HEAD"` and inspect
   `git log <task-start>..HEAD --oneline` to prove that history matches the plan.
5. Inspect `git status --short` and distinguish preserved pre-existing changes
   from task-owned changes.
6. Use these three explicit handoff states for every change task, including the
   focused lane:
   - `Quality`: exact checks and results, checks not run with reasons, and
     remaining risks.
   - `History`: the task commit range and the planned-slice-to-commit mapping.
   - `Worktree`: whether it is clean, contains preserved pre-existing changes,
     or contains user-requested uncommitted task changes.
7. Alongside those states, report changed behavior and any architecture or
   lifecycle decisions needed to understand the result.

Do not push, release, rewrite history, migrate user data, or change credentials
unless the task explicitly grants that authority.

**Complete when:** committed history matches the planned slices, the final gate
has an accurately labeled result, every task-owned change is committed unless
the user requested otherwise, the worktree's remaining changes are understood,
and the handoff can be verified without prior conversation.
