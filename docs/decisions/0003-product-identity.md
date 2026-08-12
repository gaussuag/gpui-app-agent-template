# ADR 0003: Cargo-owned product identity and Windows resource ownership

- Status: accepted
- Date: 2026-08-12
- Owners: repository, desktop, and scripts owners

## Context

The template previously spread its executable name and display title across the
desktop manifest, GPUI adapter, and PowerShell entry points. A repository made
with GitHub **Use this template** therefore remained branded as the template.
The Windows executable also had no project icon or `VERSIONINFO`.

GPUI `0.2.2` already embeds resource ID 1 when `windows-manifest` is enabled.
That manifest owns the validated PerMonitorV2 and Common Controls declarations.
Adding a second application manifest would create competing resource owners.

## Decision

The `desktop` Cargo manifest is the product identity source:

- workspace package version is the product version;
- the single binary target is the executable basename;
- package description is the file description;
- `package.metadata.winresource` supplies ProductName, CompanyName,
  LegalCopyright, and OriginalFilename;
- `crates/desktop/resources/windows/app.ico` supplies the executable icon.

The desktop build script validates those fields, embeds icon and `VERSIONINFO`
through exact `winresource`, and exports the display name to desktop Rust code.
Desktop passes a small immutable launch identity into `app-ui`; `app-ui` does
not read Cargo files or Windows resources.

GPUI remains the only application-manifest owner. The desktop resource build
does not set a manifest. A future UAC or compatibility change must first
replace this decision with one application-owned merged manifest and prove the
resolved GPUI feature graph no longer embeds a competing resource ID 1.

GitHub Template remains the distribution entry. An in-place initializer uses
repository facts only as suggestions, updates allowlisted identity fields, and
then verifies source and built-artifact identity. Architecture role packages
`app-core`, `app-ui`, and `desktop` keep their stable names.

## Alternatives

- A second create-directory generator was rejected because it duplicates the
  GitHub Template path and would require a second template copy.
- Repository-name global replacement was rejected because repository, binary,
  display, publisher, and Windows Shell identities have different constraints.
- A custom product configuration schema was rejected in favor of Cargo fields
  and the existing `winresource` metadata contract.
- A ProductIdentity trait/registry was rejected because static build identity
  has one implementation and no real adapter seam.
- Application-owned manifest embedding is deferred until the GPUI manifest can
  be disabled and the merged manifest verified as the sole resource ID 1.

## Consequences

- Resource compilation failure is a Windows build failure, not a warning.
- Development identity may retain a neutral template icon and unconfigured
  publisher; release readiness rejects both.
- Runtime display identity and PE metadata derive from the same Cargo manifest.
- Installer, signing, AppUserModelID, settings, logging, and business adapters
  remain outside this decision.

## Validation

- Product identity parser and script policy self-tests.
- Template, development, and release profile checks.
- Windows debug/release build with PE `VERSIONINFO`, icon, and embedded GPUI
  manifest inspection.
- A generated-repository fixture with different repository, binary, display,
  publisher, Unicode, and spaced-path values runs the canonical Windows gate.

## Rollback and evolution

Removing product initialization requires restoring the fixed binary/title and
deleting the resource build dependency. Replacing `winresource` or changing
manifest ownership requires a new ADR, lockfile review, artifact inspection,
and native Windows smoke evidence.
