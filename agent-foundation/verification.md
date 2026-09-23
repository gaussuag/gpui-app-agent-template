# Verification by impact

Use the project's acceptance criteria and command map. Choose the smallest
check that reaches the changed behavior, including affected callers and shared
dependencies. Widen the scope when a shared implementation, dependency, build
setting or new failure makes neighboring behavior uncertain.

## Choose when to run

- During implementation: compile early and run the focused behavior check.
- At feature handoff: review the complete diff and cover affected integration
  paths. Existing passing evidence can contribute when its inputs remain valid.
- At integration/release: run the project's full gate and required environment
  checks. Intermediate commits do not independently trigger this gate.

Test at the lowest stable seam that observes the requirement. Use real platform
or visual evidence when lower layers cannot establish it. Add positive/negative
fixtures for changed acceptance checkers; reserve deliberate fault injection for
claims whose test sensitivity is otherwise uncertain.
For styling-only changes, visual evidence can suffice when an assertion would
only repeat styling code. Preserve existing regression coverage.

## Reuse evidence, not assumptions

A result remains useful while the relevant source, dependencies, test logic,
build configuration and required environment remain applicable. A commit,
documentation edit or new conversation alone does not invalidate it. Explain
only non-obvious reuse or omissions; no mandatory matrix or per-check form.

After a failed gate, repair the cause and rerun affected checks, then any stages
not reached. Restart the entire gate only if the change invalidated its earlier
results. Group related test additions before broad validation.

## Distinguish outcomes

- **PASS**: the check completed and established its stated claim.
- **FAIL**: a behavior, build or assertion failed; diagnose before retrying.
- **BLOCKED**: an environment prerequisite prevented checking the claim. Record
  the missing prerequisite and continue independent work. Retry when it changes.
- **NOT RUN**: outside the affected scope or intentionally deferred; state any
  remaining acceptance work at handoff.

BLOCKED and NOT RUN are not passes. Avoid repeated attempts with unchanged
inputs and environment. When a desktop, device or service is unavailable,
preserve focused diagnostics and a runnable manual acceptance path.

Keep full logs in project-owned artifacts. For a long task, retain a compact
note with the useful command/result, relevant revision or changed inputs, and
what would invalidate it. No foundation-owned state or certification ledger.
