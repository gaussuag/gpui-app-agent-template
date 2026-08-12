# UI dependency policy

## Baseline

The authoritative versions are the exact requirements in the root
`Cargo.toml`; `Cargo.lock` records the resolved package identities and registry
checksums. GPUI and gpui-component form one bill of materials and are reviewed
as a unit.

The baseline permits one registry identity for `gpui` and one for
`gpui-component`. `scripts/check-architecture.ps1` enforces that property.

The desktop build additionally pins exact registry versions of `toml` and
`winresource`. They validate Cargo-owned product identity and embed ICON plus
VERSIONINFO. `winresource` is not an application-manifest owner; GPUI's
`windows-manifest` feature remains the sole source of manifest resource ID 1.

## Resolved feature contract

Cargo unions features enabled through every dependency edge.
`default-features = false` on this workspace's direct GPUI edge does not mean
the resolved GPUI package has no default features: in the reviewed BOM,
gpui-component enables `gpui/default`. Treat the resolved dependency graph as
authoritative and inspect it during every UI BOM upgrade.

`windows-manifest` is an explicit project requirement. It is enabled directly
so the expected Windows DPI and Common Controls manifest behavior does not
depend on a transitive default. This does not disable features enabled through
other dependency edges.

Inspect the production Windows feature graph with:

```powershell
cargo tree `
  --locked `
  --package desktop `
  --target x86_64-pc-windows-msvc `
  -e features `
  -i gpui@0.2.2
```

## Upgrade procedure

1. Create a dependency-only branch.
2. Read the target gpui-component release manifest and confirm its declared
   GPUI version.
3. Update both exact root requirements together.
4. Regenerate and inspect `Cargo.lock`.
5. Confirm `cargo metadata --locked` contains one registry identity for each UI
   package.
6. Run `scripts/check.ps1` on Windows.
7. Launch the application and verify open, render, input, background completion,
   reset/cancellation, window close, and process exit.
8. Record breaking interface migrations and platform changes in the pull
   request.

## Git and fork escape hatch

A feature unavailable in the registry baseline may justify a pinned git
revision. Before adopting it, add an ADR containing:

- upstream repository and exact revision;
- component revision known to match it;
- package identity strategy for gpui, gpui_platform, and gpui_macros;
- fork delta and owner, if any;
- Windows verification evidence;
- upgrade and removal plan.

Moving branches and unpinned git sources are not release inputs. Do not combine
a `rev` source with a transitive unqualified git source unless package identity
has been deliberately unified and verified.
