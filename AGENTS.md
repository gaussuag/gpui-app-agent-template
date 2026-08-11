# Agent operating contract

## Start every task

1. Read the current request, this file, the root `Cargo.toml`, and the target
   crate before editing. Source and `Cargo.lock` outrank old discussion.
2. Read `docs/architecture.md` when changing state, async work, ownership,
   shutdown, or crate dependencies.
3. Read `docs/dependency-policy.md` when changing Rust, GPUI,
   gpui-component, features, sources, patches, or the lockfile.
4. Read `docs/windows-platform.md` when touching windows, native APIs,
   packaging, installers, paths, or platform-specific code.
5. Define acceptance evidence using `docs/agent-task-template.md` for any task
   that spans more than one module or changes runtime behavior.

## Preserve these invariants

- `app-core` remains UI-free. It owns state transitions and returns effects;
  `app-ui` interprets effects as GPUI work.
- `render` reads prepared state and builds elements. I/O, sleeps, blocking
  waits, long locks, and task creation happen outside `render`.
- Background work returns immutable results. Apply results on the GPUI
  foreground executor and reject stale revisions.
- Store every non-process-lifetime `Task`, `Subscription`, channel owner, and
  native handle in the entity or module that controls its lifetime.
- Errors crossing I/O or platform seams become typed outcomes and visible UI
  state where the user can act on them.
- GPUI and gpui-component stay on one reviewed bill of materials. A fork records
  its upstream base, delta, owner, and removal plan in an ADR.

## Delivery

Keep the diff within the requested behavior. Run `scripts/check.ps1` before
claiming completion. Report formatting, Clippy, tests, architecture checks, and
the Windows build separately; an unrun gate is not a passing gate. Add or update
tests at the module interface, so implementation refactors do not rewrite the
test suite.
