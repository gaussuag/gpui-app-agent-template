# ADR 0004: Executable change contracts (superseded)

- Status: superseded
- Superseded by: [ADR 0008](0008-spec-driven-development.md)

The previous workflow introduced machine-readable change contracts, lanes,
scope budgets and protected-path checks. It was intended to bound autonomous
Agent edits, but made ordinary development maintain a second specification
and a substantial validation system.

The active workflow now reuses the developer's spec, checks the actual diff
and verifies behavior. The old protocol is not required. Its full rationale
and implementation remain in Git history at `907b7cb`.
