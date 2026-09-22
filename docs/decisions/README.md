# Architecture decisions

Use an ADR for a lasting cross-cutting choice whose rationale is not evident
from code: dependency/source strategy, module boundaries, persistent formats,
platform support, or shutdown protocols involving external resources.

Routine features, local ownership refactors and individual Task lifetimes do
not each need an ADR. Reuse the developer's technical plan when it already
records the decision; link it or preserve only the lasting rationale here.
The [short template](../templates/adr.md) is optional.

Current decisions:

- [Application-owned last-window exit](0002-last-window-exit.md)
- [Cargo-owned product identity](0003-product-identity.md)
- [GPUI Kit facade](0007-gpui-kit.md)
- [Spec-driven development and focused verification](0008-spec-driven-development.md)
- [Native overlay boundary and coordinated exit](0009-native-overlay-lifecycle.md)

Historical decisions (superseded):

- [Original UI bill of materials](0001-ui-bom.md)
- [Executable change contracts](0004-executable-constitution-core.md)
- [Contract provenance](0005-authoritative-change-contract-resolution.md)
- [Accepted contract limitations](0006-executable-constitution-residual-disposition.md)
