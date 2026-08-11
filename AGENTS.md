# Agent operating contract

## Start every task

1. Read the request, `git status`, this file, the root manifest, and the nearest
   scoped `AGENTS.md` before editing. Current source and `Cargo.lock` outrank
   plans, comments, old discussion, and remembered APIs.
2. For any runtime, state, async, error, render, lifecycle, or multi-module
   change, follow [the Agent workflow](docs/agent-workflow.md) and apply
   [the development standard](docs/agent-development-standard.md).
3. Read [the architecture](docs/architecture.md) when changing commands,
   effects, state ownership, task ownership, shutdown, or crate dependencies.
4. Read [the dependency policy](docs/dependency-policy.md) before changing Rust,
   GPUI, gpui-component, features, sources, patches, or the lockfile.
5. Read [the Windows contract](docs/windows-platform.md) before changing
   windows, native APIs, paths, packaging, installers, or platform code.
6. Use [the task specification](docs/agent-task-template.md) for runtime changes
   or work spanning more than one module. Its acceptance evidence is the bound
   of the task; unresolved items remain incomplete.

Before implementation, record the current chain in task context: entry,
authoritative owner, side effect, background/foreground boundary, stale guard,
notification/render, failure/recovery, and close/quit behavior. A documentation-
only change may shorten this record but still identifies its source of truth.

## Repository invariants

- Dependency direction is `desktop -> app-ui -> app-core`; only `app-ui` depends
  on GPUI and gpui-component.
- Every mutable state and resource has one authoritative owner. Read-only
  snapshots may be copied; writes return to the owner with revision identity.
- Render reads prepared state and builds elements. External I/O, sleeps,
  blocking waits, long locks, and task creation stay outside render.
- Background work returns immutable values. UI state changes only on the GPUI
  foreground context after owner and stale-request checks.
- Every Task, Subscription, channel endpoint, worker, process, watcher, socket,
  device, temporary artifact, and native handle has a named lifecycle owner and
  stop path.
- User-triggered failures become typed outcomes, visible recovery state, and
  redacted diagnostics.
- GPUI and gpui-component remain one reviewed bill of materials. A fork or git
  source requires an ADR with upstream base, delta, owner, and removal plan.

## Delivery

Keep the diff and commits within the requested behavior. Follow
[the Git commit policy](docs/git-commit-policy.md). Run focused tests first and
then `scripts/check.ps1` before claiming completion. Report formatting, Clippy,
tests, architecture/Agent checks, Windows build, manual smoke, and packaging
separately; an unrun gate is not a passing gate.
