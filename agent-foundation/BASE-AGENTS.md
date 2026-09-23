# Agent foundation

Read this once when entering a project. The project's root agent instructions
must also point to its architecture, commands and acceptance requirements.
Resolve relative links in this document from this directory.

## Work from evidence

Read the requested outcome, current changes, affected implementation, adjacent
tests and scoped instructions. The spec defines intended behavior; source and
locked dependencies establish current facts. Resolve material conflicts with
the user. Proceed autonomously on implementation choices within that scope.

Build a small working path and validate the highest uncertainty early. Reuse
the supplied spec. Keep a short plan in task context; use one project-owned
progress note only when a long task needs durable state.

Before code changes, apply [engineering rules](engineering.md). Before choosing
or rerunning checks, apply [verification](verification.md) and the project's
command map. Read-only questions end with an evidence-backed answer.

## Finish at the right scale

Review the actual diff against the requested behavior and recovery paths.
Report changes to tests or checkers that alter acceptance, preserve the intended
requirement, and prove the replacement. Keep unrelated user work intact.

A local commit or small development step is not a full-validation milestone.
Follow the project's commit policy. Report the delivered outcome, actual checks,
unresolved limitations and a runnable acceptance path. Push, publish, destructive
data changes and history rewriting require corresponding user authorization.

## Resume without conversation history

Use the root entry, project map, Git diff and the relevant spec first. For a
continuing task, read its existing progress note if available: remaining work,
last useful checks, and why any evidence is still valid or blocked. Recover
missing facts from source and logs. Do not infer success from a previous summary
or rerun everything merely because the conversation is new.

Keep durable rules here, project decisions in the project, and transient results
in task context or project-owned artifacts. Add a rule only for a demonstrated
recurring trap; prefer a type, test or existing check when it expresses the need.
