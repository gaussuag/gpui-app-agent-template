# Contributing

Start from the issue/spec or technical plan and follow
[the development workflow](docs/agent-workflow.md). Keep the change focused,
preserve unrelated work, and pair behavior with relevant tests.

Use [implementation rules](docs/agent-development-standard.md) for Rust/GPUI
boundaries and [the testing guide](docs/testing-standard.md) for check selection.
Run `scripts/check.ps1` for code/build/automation changes. For docs-only edits,
run `scripts/check-docs.ps1` and `git diff --check`. Template generation,
identity, UI-stack and build/verification changes also exercise
`scripts/test-generated-project.ps1`.

Commit coherent changes with clear messages. No commit-message hook or body
schema is required. If an older clone configured `core.hooksPath=.githooks`,
the removed hook no longer runs; remove that local setting if no other hooks
use it.

A pull request explains what changed, links the supplied spec, reports checks
and remaining limitations, and gives a short runnable acceptance path. Record
an [ADR](docs/decisions/README.md) only for a lasting cross-cutting choice.
