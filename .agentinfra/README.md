# Executable Constitution data

This directory contains deterministic governance inputs, not proof that a
change passed. The machine-readable policy owns lanes, verification profiles,
protected paths, and reliably observable budget indicators. Repository
architecture, dependency identity, product identity, and the complete quality
gate remain owned by their existing specialist scripts.

Full and governance changes add one ready ChangeSpec under `changes/` in the
first task commit. Final validation resolves it automatically from the
runner-owned task start and Git provenance; a file's directory alone does not
make it committed. Focused and bot changes use a temporary ChangeSpec generated
outside the repository. Runner-generated evidence and remote trust controls are
intentionally deferred. The human lifecycle, rejection/review boundary, and
local command order are in
[the executable change contract](../docs/change-contract.md).
