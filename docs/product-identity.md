# Product initialization and Windows identity

This repository is distributed through GitHub **Use this template**. The copied
repository is then initialized in place; no second project directory or hidden
template copy is created.

## First initialization

Clone the new repository, leave the worktree clean, and preview the plan:

```powershell
.\scripts\init-project.ps1 `
  -ProductSlug invoice-studio `
  -DisplayName "Invoice Studio" `
  -Publisher "Example Company" `
  -WhatIf
```

Remove `-WhatIf` to apply it. `ProductSlug` may be omitted; the script suggests
one from `origin` and then the checkout directory. The script prints the entire
plan and asks for confirmation. Automation supplies all values plus
`-Confirm:$false`.

`ProductSlug` is lowercase ASCII kebab-case. It becomes the executable basename
and is immutable after initialization. `DisplayName`, description, publisher,
copyright, and icon remain configurable:

```powershell
.\scripts\configure-product.ps1 `
  -DisplayName "Invoice Studio Pro" `
  -Publisher "Example Company" `
  -IconPath .\branding\invoice.ico
```

Both commands reject a dirty worktree, edit an allowlist of identity fields,
run source identity checks, and run the full repository gate by default. Use
`-SkipFullCheck` only when an enclosing deterministic check runs
`scripts/check.ps1` immediately afterward.

## Source of truth

The `desktop` Cargo manifest owns product identity:

| Cargo fact | Consumer |
|---|---|
| single `[[bin]].name` | Cargo target, run/smoke scripts, `InternalName`, `OriginalFilename` |
| package `version` | PE file and product versions |
| package `description` | README product summary and PE `FileDescription` |
| `metadata.winresource.ProductName` | GPUI window/top-level label and PE `ProductName` |
| `CompanyName` and `LegalCopyright` | PE metadata and LICENSE |
| `resources/windows/app.ico` | Windows executable icon |

`build.rs` validates the manifest, exports `PRODUCT_DISPLAY_NAME`, and embeds
ICON plus `VERSIONINFO`. `desktop` creates an immutable `LaunchIdentity` and
passes it to `app-ui`; UI code does not parse manifests or read resources.

GPUI's exact `windows-manifest` feature remains the sole owner of application
manifest resource ID 1. The desktop resource build intentionally does not call
`set_manifest` or `set_manifest_file`. The built-artifact check extracts ID 1
and proves PerMonitorV2 plus Common Controls v6.

## Stable architecture and intentional exclusions

Initialization does not rename the role crates `app-core`, `app-ui`, or
`desktop`, perform a repository-wide replacement, or add runtime settings,
logging, telemetry, installer, signing, AppUserModelID, or business services.
Those are product decisions, not template identity.

## Profiles and evidence

- `Template` requires the exact sentinels and neutral icon checked into this
  repository.
- `Development` requires product slug/display initialization but permits the
  neutral icon and unconfigured publisher.
- `Release` additionally rejects the placeholder publisher and neutral icon.

`scripts/check-product.ps1` validates Cargo/README/LICENSE consistency, ICO
structure, and optionally PE resources. `scripts/test-generated-project.ps1`
copies the repository to a path containing spaces, creates a Git repository,
initializes a Unicode-named product with another icon, runs the canonical gate,
builds release, and inspects the PE. CI runs this isolated fixture after the
template gate.

The ownership rationale and manifest collision rule are recorded in
[ADR 0003](decisions/0003-product-identity.md).
