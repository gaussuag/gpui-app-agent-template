# UI dependency policy

## Baseline

The root `Cargo.toml` pins the application's exact registry `gpui-kit`
requirement and explicitly enables `component` and `assets`. Only `app-ui`
depends on Kit; application imports use `gpui_kit` and
`gpui_kit::component`. Kit brings the GPUI backend, base, styled components,
and default icon assets as one compatibility unit.

`Cargo.lock` records the resolved versions, registry identities and checksums.
`workspace.metadata.ui-bom.gpui-pre` records the reviewed backend snapshot.
The architecture gate compares that declaration to the resolved graph; it is
not a Cargo version constraint. Keep the lockfile committed and build with
`--locked`. A lockfile refresh must reapply the reviewed snapshot if Kit's
semver range would otherwise select a newer, incompatible backend.

The initial pairing is Kit 0.6.4 with GPUI pre 0.3.5. Kit's permissive range
also resolves 0.3.6, but that snapshot changes the inspector callback API and
does not compile with component 0.6.4. See [ADR 0007](decisions/0007-gpui-kit.md).

`scripts/check-architecture.ps1` requires one registry identity per Kit layer
and resolved `gpui-pre-*` package, matching Kit layer versions and matching
GPUI snapshot versions. The republished `gpui-pre-reqwest` fork retains
reqwest's version and is excluded only from snapshot-version equality.
The gate rejects legacy GPUI packages and direct UI dependencies outside the
app-ui Kit facade. Its positive/negative fixtures run in the full gate.

The desktop build also pins exact `toml` and `winresource` versions for
Cargo-owned product identity, ICON and VERSIONINFO.

## Features and Windows resources

Cargo unions features across dependency edges. Kit's explicit component and
assets features do not disable defaults enabled by its transitive dependencies.
Initialize with `gpui_kit::init` before creating components and launch with
`gpui_kit::application().with_assets(gpui_kit::assets::Assets)`.

On Windows, the reviewed `gpui-pre-platform` manifest enables
`gpui-pre/windows-manifest`. That backend remains the sole owner of manifest
resource ID 1; desktop's `winresource` build must not add a second manifest.
The architecture gate checks the resolved feature, and the product gate
extracts the executable's PerMonitorV2 and Common Controls v6 declarations.

Inspect the production Windows graph without development dependencies:

```powershell
cargo tree --locked --package desktop --target x86_64-pc-windows-msvc -e normal,build,features -i gpui-pre
```

The app-ui feature and development dependency both enable
`gpui-kit/test-support`, which forwards to the matching backend, base and
component harnesses. Runtime application code does not enable test-support.

## Upgrade procedure

1. Create a dependency-only branch and read the target registry manifests.
2. Update Kit's exact requirement and the reviewed snapshot declaration together.
3. Resolve dependencies and pin the reviewed backend, for example:
   `cargo update -p gpui-pre-platform --precise 0.3.5` for this baseline.
4. Inspect the complete lockfile and production Windows feature graph.
5. Run `scripts/check-architecture.ps1` and `scripts/check.ps1` on Windows.
6. Verify launch, render, input, background completion, reset/cancellation,
   window close and process exit. Report manual DPI and packaging separately.
7. Record API adaptations and platform changes; supersede the BOM ADR when the
   compatibility or source strategy changes.

## Git and fork escape hatch

A capability unavailable in the registry baseline requires an ADR before
adopting a pinned git revision. Record upstream repository/base, exact revision,
matching Kit/component revision, package identity strategy, fork delta and
owner, Windows evidence, upgrade and removal plan. Update the dependency
checker and its fixtures to enforce the new decision; an ADR alone does not
change what the checker accepts.

Moving branches and unpinned sources are not release inputs. Do not combine
a pinned source with a transitive unqualified git source without deliberately
unifying and verifying the package identities.
