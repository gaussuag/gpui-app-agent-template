# Architecture decision records

Create the next numbered ADR from [the template](../templates/adr.md) before a
change alters any of these contracts:

- authoritative state or resource owner;
- crate dependency direction or a new long-lived service boundary;
- persisted data, protocol, wire format, or migration semantics;
- cancellation, close, Quit, shutdown, drain, flush, or join semantics;
- supported platform tier or a new Win32/COM/FFI/unsafe boundary;
- GPUI/gpui-component source, git revision, fork, or package identity strategy;
- an exception to a repository source-risk gate.

Use `proposed`, `accepted`, `superseded`, or `rejected` status. An accepted ADR
records the current decision, alternatives, consequences, direct validation,
owner, and rollback/upgrade/removal path. Update or supersede a decision instead
of silently changing the behavior it documents.

Current decisions:

- [ADR 0001: Registry-first GPUI bill of materials](0001-ui-bom.md)
- [ADR 0002: Application-owned last-window exit](0002-last-window-exit.md)
- [ADR 0003: Cargo-owned product identity and Windows resource ownership](0003-product-identity.md)
