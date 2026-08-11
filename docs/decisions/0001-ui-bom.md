# ADR 0001: Registry-first GPUI bill of materials

- Status: accepted
- Date: 2026-08-11

## Decision

Start with exact registry requirements `gpui 0.2.2` and `gpui-component 0.5.1`,
commit `Cargo.lock`, and verify a single registry package identity for both.
Pin Rust 1.97.1 and target `x86_64-pc-windows-msvc`.

## Context

GPUI is pre-1.0 and its git interface changes frequently. gpui-component 0.5.1
was released against GPUI 0.2.2. A registry pair gives agents and maintainers a
versioned source surface, checksums, and lower package-identity complexity than
coordinating unpinned Zed and component git tips.

## Consequences

- The baseline favors reproducibility over unreleased features.
- UI-stack upgrades are isolated changes and validated on Windows.
- A future git revision or fork requires a new ADR and an explicit compatibility
  and package-identity plan.
