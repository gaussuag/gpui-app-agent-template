# Development workflow

Start from the developer's spec or technical plan. This workflow connects that
input to the repository's implementation and verification tools. Read-only
investigations stop at an evidence-backed answer without edits or commits.

## 1. Understand and locate

Read the requested behavior, affected implementation, adjacent tests and scoped
instructions. Inspect Git status and the current diff, including staged work.
Use the root manifest and lockfile when selecting dependency APIs.

Identify where the behavior belongs and which observable results will prove it.
Reuse the supplied spec rather than translating it into another mandatory
document. Keep a short plan in task context; for long tasks, retain progress and
unresolved decisions in one task note.

Proceed when the outcome and affected owners are clear. Ask only for missing
decisions that materially affect behavior, data safety or scope; continue
independent work while waiting. Resolve local implementation choices yourself.

## 2. Implement and test

Build a small end-to-end path through the existing owners. Follow
[implementation rules](agent-development-standard.md) and choose tests from
[the testing guide](testing-standard.md). Validate the highest uncertainty early:
compile a new API integration before broad migration, exercise native startup
before polishing platform code, and test recovery before extending writes.

For asynchronous changes, trace request, completion, stale-result rejection and
owner shutdown. Record complicated resource interactions near their owner or in
the supplied design; a simple owned Task does not require a separate ledger.
Create an [ADR](decisions/README.md) only for a lasting cross-cutting decision.

A failing check is feedback: diagnose the cause, repair the relevant behavior,
and rerun the affected checks. Keep retries evidence-driven. Repeated identical
failures require a new hypothesis or a clear blocker, not blind reruns.

## 3. Verify the result

Review the diff against the spec, including recovery paths, unrelated edits and
changes to tests/checkers. Preserve acceptance intent: do not make a gate green
by disabling tests or weakening requirements. When a checker is outdated,
explain the correction and test both accepted and rejected behavior.

Run focused checks during development and `scripts/check.ps1` for code, build,
dependency or automation changes. Documentation-only changes can use
`scripts/check-docs.ps1` plus `git diff --check`. Run the generated-project
fixture for template initialization, identity, UI-stack or build/verification
changes that affect generated applications. See the testing guide for details.

A result is verified only by a completed check on the delivered content.
Report failures and unrun checks with reasons. Keep full logs outside task
prose; read failure details and completion summaries rather than repeatedly
loading unchanged logs.

## 4. Commit and hand off

Create coherent local commits with clear messages unless the user requests an
uncommitted handoff. Stage explicit task paths and inspect the full staged diff.
Preserve unrelated work, including staged changes; use isolation when needed.
There is no required commit-body template or preliminary spec commit.

After checks pass, commit the verified content and confirm the resulting diff
and worktree. Rerun checks if relevant content changes; a commit alone does not
invalidate results. Push, PR creation, release and history rewriting require
separate authorization.

Report the implemented outcome, how to run and accept it, actual check results,
and any unresolved limitations. Include commit IDs and remaining worktree
changes briefly. UI features need a few concrete acceptance actions and expected
results; include actual screenshots when visual changes warrant them.
