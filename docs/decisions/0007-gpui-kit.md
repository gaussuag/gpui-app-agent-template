# ADR 0007: GPUI Kit application facade

- Status: accepted
- Date: 2026-09-21
- Owners: app-ui and repository automation owners
- Supersedes: [ADR 0001](0001-ui-bom.md)

## Decision

Use the exact registry `gpui-kit` requirement in the root manifest as the
application's UI entry point. Enable `component` and `assets` explicitly, and
commit the entire resolved stack in `Cargo.lock`. Application code imports
`gpui_kit` and `gpui_kit::component`; it does not directly depend on the old
`gpui` or `gpui-component` packages. Kit's `application`, `init`, actions and
test macro keep startup and tests on the same supported facade.

The initial facade version is 0.6.4. Its published manifest permits GPUI pre
0.3.5-compatible releases; the lockfile, not the upstream main branch, records
the reviewed resolution. Pin the initial snapshot family to 0.3.5: testing
0.3.6 found an incompatible `register_inspector_element` callback in component
0.6.4. Record the reviewed snapshot in `workspace.metadata.ui-bom` and reject
unreviewed lockfile upgrades in the architecture gate. `gpui-pre-*` packages
are upstream snapshots published with Zed's license and provenance. They are
registry dependencies, not a local fork. Review their manifests, feature graph
and package identities together.

Preserve the sample's `desktop -> app-ui -> app-core` separation, owned task,
revision guard, and application-owned last-window exit. This is a template
example, so API adaptation is preferred over preserving obsolete GPUI calls.
No JavaScript shell, persistence, or new service abstraction is introduced.

## Windows and testing

The resolved `gpui-pre-platform` Windows dependency enables
`gpui-pre/windows-manifest`. GPUI remains the only manifest resource owner;
desktop still embeds only icon and VERSIONINFO. Check the Windows production
feature graph and the built executable, rather than retaining the old direct
GPUI dependency merely to enable a feature. This preserves ADR 0003's ownership.

Use `gpui-kit/test-support` and `#[gpui_kit::test]` for deterministic UI tests.
Import test types explicitly: a wildcard import can shadow Rust's built-in
`#[test]`. Keep real component click, Action, completion, cancellation,
owner-drop and last-window tests. Native first-frame and close smoke and PE
resource validation remain separate required evidence.

## Enforcement and recovery

The architecture checker requires one registry identity for each Kit layer and
each resolved `gpui-pre-*` package, aligned snapshot versions (except the
republished reqwest fork, which retains its own version), the Windows
manifest feature, and Kit as app-ui's only direct UI dependency. It rejects
legacy GPUI packages and UI dependencies in the domain or desktop crate.
Positive and negative metadata fixtures test this contract without network or
mutation of the user's checkout.

Upgrade the facade and lockfile as one compatibility unit and run the full
Windows gate. Roll back the atomic migration commit and lockfile if integration
fails; no user data migration is needed. A future official GPUI backend switch
should remain behind Kit unless evidence requires a new dependency decision.

## Alternatives and evidence

Keeping the old pair would leave new template users on the old application API.
Directly coordinating GPUI pre, platform, base, component and assets would add
multiple application dependency edges already maintained by Kit.

Source evidence: the registry gpui-kit 0.6.4 manifest and public facade, and the
resolved GPUI pre platform manifest. Verification commands are
`scripts/test-ui-dependencies.ps1`, `scripts/test.ps1 -Suite gpui`,
`scripts/check-architecture.ps1`, and `scripts/check.ps1`. Their execution
results belong in commit evidence and delivery; this decision is not proof of
a passing build, smoke, manual DPI check, or packaged release.
