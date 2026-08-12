# GPUI Agent Template

<!-- product-summary:start -->
A Windows-first Rust and GPUI desktop application.
<!-- product-summary:end -->

## What is included

- Rust 1.97.1 and Rust 2024, pinned by `rust-toolchain.toml`.
- A registry-only UI bill of materials: `gpui = 0.2.2` and
  `gpui-component = 0.5.1`, both exact requirements.
- A UI-free state machine in `app-core`.
- A single GPUI adapter in `app-ui` with owned background task cancellation and
  stale-result rejection.
- GPUI `test-support` with typed Action, real gpui-component click,
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
Clippy, explicit pure-core/GPUI/workspace test layers, Agent/document/source-risk
contracts, dependency architecture, policy self-tests, and an explicit
`x86_64-pc-windows-msvc` build with `--locked`, followed by a native first-frame,
Action, close, and process-exit smoke. Changes to template initialization or
product identity additionally run `scripts/test-generated-project.ps1`; CI runs
both scripts. Specialized manual Windows, packaging, performance, or
accessibility checks are reported separately.

Run a focused layer while developing:

```powershell
.\scripts\test.ps1 -Suite core
.\scripts\test.ps1 -Suite gpui
.\scripts\smoke.ps1
.\scripts\test-generated-project.ps1 # template identity/initialization changes
```

## Repository map

```text
crates/app-core/   Domain state and effects; never depends on GPUI
crates/app-ui/     The only GPUI and gpui-component adapter
crates/desktop/    Windows executable and process-level startup
docs/              Architecture, decisions, templates, and Agent guidance
scripts/           Canonical local verification and run commands
```

Read [the architecture](docs/architecture.md) before adding a subsystem. Read
[the dependency policy](docs/dependency-policy.md) before changing the UI
stack. Coding agents start with [AGENTS.md](AGENTS.md).

## Code Agent entry

Agents begin at [the root operating contract](AGENTS.md), then read the nearest
scoped `AGENTS.md`. Runtime and multi-module tasks follow
[the Agent workflow](docs/agent-workflow.md), fill
[the task specification](docs/agent-task-template.md), and apply
[the development standard](docs/agent-development-standard.md) and
[the automated testing standard](docs/testing-standard.md). Changes to
ownership, shutdown, persistence/protocols, platform tier, unsafe boundaries, or
the UI dependency source use [an ADR](docs/decisions/README.md).

The rules describe supervised repository work; they do not authorize pushes,
releases, user-data migration, or credential changes. Executed checks and unrun
dynamic validation are reported separately.

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
7. Complete [the task specification template](docs/agent-task-template.md) for
   non-trivial agent work.

## Dependency upgrades

GPUI and gpui-component are one compatibility unit. Upgrade them in one change,
commit the new lockfile, confirm one registry package identity for each, and run
the complete Windows check. Git dependencies, branches, forks, and `[patch]`
entries require an architecture decision record and are not baseline upgrades.
