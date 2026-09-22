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

The overlay demo selects an external window and attaches ordinary Kit content
to its client area:

```powershell
cargo run --locked -p desktop -- --overlay-demo
```

Refresh the list, select a host, attach, then return to that host to see the HUD.
HUD mode passes clicks and wheel input through; Interactive mode accepts input
in the overlay. Esc first lets the focused component dismiss its transient
state, then returns to HUD. The control window can detach or switch hosts, and
its ordinary-window preview uses the same business content. `--overlay-demo`
and `--smoke-test` cannot be combined. See the
[overlay contract](docs/overlay-gpui-spec.md) and
[current verification record](docs/overlay-implementation-progress.md).

The [host-relative presentation design](docs/overlay-host-presentation-design.md)
describes inactive visibility, Z-order following, and user-triggered host promotion.
The overlay remains visible while its host is inactive, follows its Z-order band,
and is naturally occluded by other windows. Clicking interactive content requests
one asynchronous host promotion. Already-submitted requests can execute late;
an unknown result requires reattachment before another promotion. Real desktop
acceptance is tracked separately from unit tests.

The `--overlay-demo` control window has a “四角定位标记：开 / 关” option,
off by default. It updates attached demo content without reattaching; the
selection is retained when switching hosts and used for newly opened previews.
Existing preview windows keep their initial setting. Automated probes explicitly
enable markers. Markers belong to `DemoContent`, not `OverlayOptions`: applications
supplying their own content to `overlay::open_window` receive no corner decoration.

The Demo also provides four margin inputs (top/right/bottom/left) and “应用边距”.
Values are nonnegative whole logical pixels and scale with the host DPI. Try
`48 / 8 / 8 / 8` for client-drawn chrome, then adjust to the host's actual layout.
Margins exclude both drawing and input; oversized values hide the overlay until
space becomes available again. Changes preserve content and apply without moving
the host. Ordinary previews are unaffected.

Business callers set `OverlayOptions.margins: OverlayMargins` and can call
`overlay.set_margins(margins, cx)` on an existing session. Use
`OverlayMargins::default()` for full-client coverage. Snapshots retain the host's
`physical_client_rect` and expose the inset `physical_overlay_rect` plus applied
`margins`. `scripts/smoke-overlay.ps1 -Suite margins` tests actual caption dragging
and border resizing on a controlled client-drawn host in both input modes.

## Verify

```powershell
.\scripts\check.ps1
```

On an unlocked desktop with Microsoft Pinyin in Chinese input mode, use
`scripts/check.ps1 -IncludeIme` and
`scripts/test-generated-project.ps1 -IncludeIme` to also verify real composition,
Escape cancellation and candidate commit in ordinary preview and Overlay.
The focused command is `scripts/smoke-overlay.ps1 -Suite ime`.
The default gate does not certify IME behavior.

`scripts/smoke-overlay.ps1 -Suite dpi` checks DPI-message synchronization at
96 → 144 → 96 DPI with an unchanged native rectangle. It only sends messages
to the fixture's own window; it does not change system scaling. This regression
is included in the default full gate. Real system-scaling acceptance is recorded
in [DPI evidence](docs/overlay-dpi-evidence.md).

`scripts/smoke-overlay.ps1 -Suite components` checks ordinary-preview/Overlay
Dialog and Sheet opening/Escape closing, menu count reset, and notification
creation through real input. It also captures tooltip and scroll screenshots
for visual inspection; those screenshots are not automatic visual assertions.
This suite is included in the default full gate.
See the [manual acceptance checklist](docs/overlay-manual-acceptance.md) for
user feedback and outstanding display-environment verification.

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
.\scripts\smoke-overlay.ps1 # controlled external host, real input, resource endurance
.\scripts\smoke-overlay.ps1 -Suite lifecycle # no synthetic input required
.\scripts\smoke-overlay.ps1 -Suite fallback # discard WinEvents and verify periodic convergence
.\scripts\test-generated-project.ps1 # template generation/build integration
```

## Repository map

```text
crates/app-core/   Domain state and effects; never depends on GPUI
crates/app-ui/     The only GPUI Kit adapter
crates/desktop/    Windows executable and process-level startup
crates/overlay-win32/ Native overlay adapter; all Win32 code stays under src/windows
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
