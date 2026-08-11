# Agent workflow

This is the ordered recipe for non-trivial repository work. The normative rules
are in [the Agent development standard](agent-development-standard.md); this
file defines when work may advance to the next step.

## 1. Establish current facts

1. Read the root and nearest scoped `AGENTS.md`.
2. Inspect `git status` and separate pre-existing changes from task changes.
3. Read the target manifest, crate root, implementation, adjacent tests, and CI
   entry used for that area.
4. Read `rust-toolchain.toml`, root UI dependencies, and the relevant lockfile
   package identities before using a GPUI API.
5. Load the conditional architecture, dependency, Windows, or decision records
   named by the root contract.

**Complete when:** task notes identify the checkout facts, applicable scoped
rules, current dependency lineage, existing user changes, and authoritative
files. Old chat or documentation is not the only evidence for any claim.

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

Use [the task specification](agent-task-template.md) to record:

- user-observable outcome and recovery behavior;
- included modules/platform tier and explicit exclusions;
- invariants and decisions that remain true;
- lifecycle, channel, capacity, privacy, and test evidence as applicable;
- the smallest atomic implementation and commit slices.

Find an adjacent pattern and test seam before creating a new abstraction. Add a
service trait or adapter seam only when a real production dependency varies and
a second implementation, normally a deterministic test adapter, is required.

Write or update an ADR before changing state/resource ownership, dependency
direction, protocol/persistence format, shutdown semantics, platform tier,
unsafe boundary, GPUI source/fork, or a high-risk-pattern exception.

**Complete when:** the requested result, excluded work, invariants, implementation
slices, and direct acceptance evidence are checkable before code changes begin.

## 4. Implement through owners

1. Make state transitions in the authoritative module.
2. Return side-effect requests as values and interpret them at the adapter seam.
3. Keep external latency off the GPUI foreground path.
4. Return small immutable results and commit them once on the foreground context.
5. Check entity/window existence and request revision before committing.
6. Notify only for semantic state changes; render only the prepared projection.
7. Update lifecycle/channel/capacity records and tests with the behavior.

Keep unrelated refactors, dependency upgrades, generated churn, and product
ideas outside the task. Preserve pre-existing changes and stage explicit paths.

**Complete when:** every changed branch returns to its authoritative owner, has
an error and lifecycle outcome, and the working diff contains only task evidence.

## 5. Verify from narrow to broad

1. Run the focused module tests named by the closest scoped instructions.
2. Exercise success, recoverable failure, cancellation/stale completion, and
   close/quit cases that apply to the change.
3. Run `scripts/check.ps1` using the pinned toolchain.
4. Perform the Windows manual smoke checklist when runtime behavior changed.
5. Inspect the final diff, task specification, new dependencies, and all
   `spawn`/channel/unsafe/exit sites touched by the change.

Record exact commands and outcomes. Report a check as `not run` with its reason
when environment or authorization prevents it; never infer a pass from source,
another platform, a workflow file, or a narrower command.

**Complete when:** each acceptance item has direct evidence, every failure is
preserved with an actionable summary, and no required item is silently omitted.

## 6. Commit and hand off

1. Review `git diff --cached` and validate one reason to revert per commit.
2. Follow [the Git commit policy](git-commit-policy.md), including Why, What,
   and Evidence sections.
3. Report changed behavior, architecture/lifecycle decisions, commits, exact
   verification results, unrun dynamic checks, and remaining risks.

Do not push, release, rewrite history, migrate user data, or change credentials
unless the task explicitly grants that authority.

**Complete when:** committed history matches the planned slices, the worktree's
remaining changes are understood, and the handoff can be verified without prior
conversation.
