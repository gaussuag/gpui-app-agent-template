# Engineering rules

Give mutable state one write owner. Use explicit states for mutually exclusive
phases and typed inputs/results at external seams. Reuse adjacent patterns;
introduce an abstraction for an actual varying dependency or a needed test seam.

Every task and external resource needs an owner and stop path. Keep simple
ownership visible in code. Document interacting workers or cleanup ordering
near their owner when code alone is insufficient.

For asynchronous work, trace request, completion, relevance and owner shutdown.
Check both liveness and request identity before applying a late result. Dropping
a task is sufficient only when cancellation leaves no required cleanup. Bound
queues and retries; make full, disconnected and partial-failure behavior explicit.

Keep blocking work outside latency-sensitive paths and locks outside suspension
points. User-triggered failures need an actionable recovery result. Preserve
error classification; redact secrets and user content from diagnostics.

For bugs, seek a small reproduction and test the actual failure path. When the
environment prevents reproduction, use source analysis or targeted diagnostics
to narrow hypotheses and label uncertainty. A fixed number of hypotheses or a
recorded red run is not a prerequisite for useful investigation. Add a regression
test where it can catch the real bug, rather than a duplicate of implementation.

Update documentation when public behavior or non-obvious rationale changes.
Tests may fail loudly on violated expectations; syntax rewrites that preserve
the same panic are not error-handling improvements. Project lint policy should
distinguish assertion failures from recoverable production errors.
