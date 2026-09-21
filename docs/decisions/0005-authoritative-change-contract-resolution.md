# ADR 0005: Contract provenance (superseded)

- Status: superseded
- Superseded by: [ADR 0008](0008-spec-driven-development.md)

The former contract resolver required an independent task-start revision and
a unique committed contract with verified Git provenance. This hardened the
machine-contract protocol rather than application behavior.

That protocol and resolver have been removed. Preserve user changes and inspect
the actual diff during delivery; no preliminary contract commit or provenance
validation is required. Full historical details remain at `907b7cb`.
