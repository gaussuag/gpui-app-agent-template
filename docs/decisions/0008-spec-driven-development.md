# ADR 0008: Spec-driven development and focused verification

- Status: accepted
- Date: 2026-09-21
- Supersedes: ADRs 0004, 0005 and 0006

## Decision

The developer supplies a feature spec or technical plan. Agents map it to the
current Rust/GPUI architecture, implement and test within that scope, and
deliver a runnable acceptance path. Clarification is for material behavior,
scope or data-safety decisions; ordinary implementation is autonomous.

Remove machine ChangeSpecs, lane/budget/provenance enforcement, source-keyword
blocking and mandatory commit-message schemas. Remove duplicate task templates
and mandatory per-resource ledgers. Preserve local commits, diff review,
behavior tests, linting, dependency compatibility, Windows smoke, product
resources and generated-project verification.

The workflow and implementation guide own the short common path. Specialist
documents load by change type. ADRs preserve durable choices. Checkers validate
technical requirements, and changes to acceptance are highlighted with tests.

## Reason and consequences

The Kit migration at commit 907b7cb demonstrated useful compile, dependency
and PE validation, while the surrounding contract protocol required separate
records and repeated checks. The intended user workflow is supervised Agent
implementation with fast human confirmation of intent and behavior.

Repository-local declarations are no substitute for independent review.
Scope is reviewed against the supplied spec and actual diff. There is no claim
of tamper-proof authorization or machine-certified Agent compliance.

Product initialization no longer edits governance policy. Cargo binary identity
determines whether generated-project testing applies. Workspace tests execute
once with all features; focused suite commands remain available.

Prior contracts, schemas, plans and validators remain available in Git history
at 907b7cb. New projects inherit the active engineering guidance, not that
retired protocol. Reconsider additional controls only after real tasks show a
specific failure that simpler types, tests or review cannot address.
