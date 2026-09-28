# Engineering rules

Give mutable state one write owner. Use explicit states for mutually exclusive
phases and typed inputs/results at external seams. Reuse adjacent patterns.
Introduce a replaceable seam when current requirements need alternative behavior
or deterministic test control of a real external dependency. Implement the
adapters needed for that variation in the same change. A single implementation
can form a deep module; possible future variation is not grounds for a seam.

Every task and external resource needs an owner and stop path. Keep simple
ownership visible in code. Document interacting workers or cleanup ordering
near their owner when code alone is insufficient.

For asynchronous work, trace request, completion, relevance and owner shutdown.
Centralize result acceptance in the state owner: verify owner liveness and
request relevance before any result-driven observable write, including content,
loading, errors and updates to other owners. Callers use that decision rather
than duplicate its checks. A generation/key may be omitted only with another
verifiable validity guarantee covering reset, target changes and close;
non-reentrancy alone is insufficient.

Dropping or aborting a task does not establish that external side effects have
stopped or rolled back. For operations with external effects, define completion
status, cleanup ownership and retry semantics after cancellation; report unknown outcomes
as unknown, not as proof that nothing happened. Dropping a task is sufficient
only when cancellation leaves no required cleanup.

Bound retries and make partial failures explicit. For high-rate streams, choose
queue limits and full/disconnected behavior by message semantics: snapshots may
coalesce; required commands need backpressure or explicit rejection. For large
collections, define pagination, retention or a capacity budget; virtual rendering
does not bound the underlying data.

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
