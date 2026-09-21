# GPUI Agent Template

<!-- product-summary:start -->
A Windows-first Rust and GPUI desktop application.
<!-- product-summary:end -->

## What is included

- Rust 1.97.1 and Rust 2024, pinned by `rust-toolchain.toml`.
- A registry-only UI stack through exact `gpui-kit`, with styled components
  and bundled icons. `Cargo.lock` records the reviewed backend snapshot.
- A UI-free state machine in `app-core`.
- A single GPUI Kit adapter in `app-ui` with owned background task cancellation and
  stale-result rejection.
- Kit `test-support` with typed Action, real component click,
  deterministic async/cancel, and owner-drop tests.
- A thin Windows process entry point in `desktop`.
- Windows CI, architecture checks, strict linting, and an agent operating
  contract.

GPUI is pre-1.0. This repository therefore treats Windows support as a
project-owned promise backed by its own build and smoke checks, not as an
assumption inherited from upstream.

## Prerequisites

1. Windows 10 or 11.
2. Visual Studio Build Tools with **Desktop development with C++** and a recent
   Windows SDK.
3. [rustup](https://rustup.rs/). Entering the repository installs the pinned
   toolchain and components declared in `rust-toolchain.toml`.

## Initialize a product

After GitHub **Use this template** and clone, preview the in-place identity plan:

```powershell
.\scripts\init-project.ps1 `
  -ProductSlug my-app `
  -DisplayName "My App" `
  -WhatIf
```

Remove `-WhatIf` to apply. The initializer requires a clean worktree, updates
only allowlisted product fields, keeps the architecture role crates stable, and
runs the full repository gate. The slug can be omitted to derive a suggestion
from the new repository. Publisher and `.ico` are optional during development
but required by the Release identity policy. See
[product initialization and Windows identity](docs/product-identity.md).

## Run

```powershell
.\scripts\run.ps1
```

The sample window demonstrates a reducer-style state module, synchronous UI
commands, background work, cancellation ownership, and revision-gated result
application.

## Verify

```powershell
.\scripts\check.ps1
```

That command is the canonical gate for ordinary changes. It runs formatting,
Clippy, one workspace test run including GPUI Kit test-support, documentation
links, dependency architecture, identity/dependency validator fixtures, and an explicit
`x86_64-pc-windows-msvc` build with `--locked`, followed by a native first-frame,
Action, close, and process-exit smoke. Changes to initialization, identity, the
UI stack, or build/verification scripts additionally run
`scripts/test-generated-project.ps1`; template CI runs
both scripts. Specialized manual Windows, packaging, performance, or
accessibility checks are reported separately.

Run a focused layer while developing:

```powershell
.\scripts\test.ps1 -Suite core
.\scripts\test.ps1 -Suite gpui
.\scripts\smoke.ps1
.\scripts\test-generated-project.ps1 # template generation/build integration
```

## Repository map

```text
crates/app-core/   Domain state and effects; never depends on GPUI
crates/app-ui/     The only GPUI Kit adapter
crates/desktop/    Windows executable and process-level startup
docs/              Architecture, decisions, templates, and Agent guidance
scripts/           Canonical local verification and run commands
```

Read [the architecture](docs/architecture.md) before adding a subsystem. Read
[the dependency policy](docs/dependency-policy.md) before changing the UI
stack. Coding agents start with [AGENTS.md](AGENTS.md).

## Code Agent entry

Provide the feature spec or technical plan. Agents start at [AGENTS.md](AGENTS.md),
map acceptance criteria to current owners, implement a small working path and
verify it through [the workflow](docs/agent-workflow.md). The
[implementation rules](docs/agent-development-standard.md) define Rust/GPUI
boundaries; [the testing guide](docs/testing-standard.md) selects relevant checks.

The supplied spec is reused without a duplicate machine contract. Routine
technical decisions are autonomous; material behavior or scope changes return
to the developer. Delivery includes local commits, actual verification results
and a runnable acceptance path for quick human confirmation. Lasting technical
choices use [ADRs](docs/decisions/README.md).

Documentation-only changes use `scripts/check-docs.ps1` and `git diff --check`.
Pushes, releases and destructive data changes require separate authorization.

## Starting a real product

1. Run `scripts/init-project.ps1` before product code enters the repository.
2. Replace the demo `AppState` commands and snapshot with product terminology.
3. Keep pure policy and state transitions in `app-core`.
4. Add a seam only when there are at least two real adapters, normally a
   production adapter and a test adapter.
5. Put filesystem, network, database, or device work behind background tasks;
   commit results to GPUI entities on the foreground executor.
6. Pair every behavior change with tests at the lowest stable seam; add
   failure/cancel/stale/owner-drop coverage and a lifecycle owner where
   applicable.
7. Follow [the workflow](docs/agent-workflow.md) from the supplied spec through
   implementation, verification and a short human acceptance path.

## Dependency upgrades

GPUI Kit and its resolved GPUI backend are one compatibility unit. Upgrade them together,
commit the new lockfile, confirm one registry package identity for each, and run
the complete Windows check. Git dependencies, branches, forks, and `[patch]`
entries require an architecture decision record and are not baseline upgrades.
