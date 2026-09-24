# Project map

This repository currently contains an application shell, an Overlay component
and its Demo. All runtime code and dependency state remain project-owned.

| Layer | Owns | Reads/depends on |
|---|---|---|
| `agent-foundation/` | Shared agent rules; stateless document checker | Its own files; explicit caller inputs |
| Root `AGENTS.md` | Entry pointers and local commit policy | Foundation and this project map |
| `crates/`, `docs/`, `scripts/`, root build files | App/component code, technical constraints, checks and evidence | Foundation rules/tools plus project dependencies |

The dependency direction is project to foundation. Foundation does not select
business tests or store project results. Cargo manifests, `Cargo.lock`, toolchain,
CI, product identity and all Rust/GPUI/Windows policies belong to the project.
This permits later foundation extraction without moving runtime crates or
pretending submodules automatically supply parent build configuration.

## Locate the work

- `app-core`: domain state and decisions; no UI dependency.
- `app-ui`: GPUI Kit entities, effects, Overlay facade and Demo content.
- `overlay-win32`: native adapter; Win32 implementation in `src/windows`.
- `desktop`: process startup and product identity.
- `scripts`: project-specific verification, initialization and run commands.

Before runtime changes, read [implementation rules](agent-development-standard.md).
For ownership or shutdown, read [architecture](architecture.md).
For dependency/features/toolchain changes, read [dependency policy](dependency-policy.md).
For native behavior or packaging, read [Windows rules](windows-platform.md).
For naming/resources/initialization, read [product identity](product-identity.md).
For lasting cross-cutting choices, consult [decisions](decisions/README.md).

For Overlay work, start from the requested change and [contract](overlay-gpui-spec.md).
When resuming its implementation, consult [progress](overlay-implementation-progress.md)
and [manual acceptance](overlay-manual-acceptance.md), then verify current code
and relevant logs. Historical pass records do not certify later changes.
Other features use their supplied spec, not the Overlay checklist.

## Run and verify

`scripts/run.ps1` starts the app; `cargo run --locked -p desktop -- --overlay-demo`
starts the component Demo. Select checks using [testing](testing-standard.md).
All project scripts run from their own root; the foundation checker receives
that root explicitly through the local wrapper.

The full local gate remains `scripts/check.ps1`; CI selects desktop-independent
groups and leaves GUI acceptance to the local Windows desktop. During development
and feature handoff, select affected groups or focused tests. Initialization and
build integration use `scripts/test-generated-project.ps1`, whose default checks
the generated product's integration rather than repeating all component tests.
Its `-FullRegression` option retains complete generated-product behavior checks.

The split changes verification scheduling, not product acceptance criteria.
Keep native/visual acceptance explicit when the required desktop is unavailable.
