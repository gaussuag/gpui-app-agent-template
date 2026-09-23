# Contributing

Start from the issue/spec or technical plan and follow
[the development workflow](docs/agent-workflow.md). Keep the change focused,
preserve unrelated work, and pair behavior with relevant tests.

Use [implementation rules](docs/agent-development-standard.md) for Rust/GPUI
boundaries and [the testing guide](docs/testing-standard.md) for check selection.
Select focused checks or `scripts/check.ps1 -Group ...` by impact. The full gate
runs at integration/release, not for every intermediate commit. Template
initialization and build integration also use `scripts/test-generated-project.ps1`;
see the testing guide for its optional full regression mode.

Commit coherent changes with clear messages. No commit-message hook or body
schema is required. If an older clone configured `core.hooksPath=.githooks`,
the removed hook no longer runs; remove that local setting if no other hooks
use it.

A pull request explains what changed, links the supplied spec, reports checks
and remaining limitations, and gives a short runnable acceptance path. Record
an [ADR](docs/decisions/README.md) only for a lasting cross-cutting choice.
