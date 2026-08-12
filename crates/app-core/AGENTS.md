# app-core owner contract

This file extends [the repository contract](../../AGENTS.md) for `app-core`.

## Owner and interface

`app-core` owns UI-independent product state, typed commands, state transitions,
effects, immutable work requests/results, revisions, and render snapshots. Its
stable caller interface is `AppState::dispatch` plus `AppState::snapshot`.

## Boundaries

- Keep this crate free of GPUI, gpui-component, Window/Entity types, native
  APIs, filesystem/network/database/device/process I/O, and executor selection.
- Encode product phases and illegal-state prevention with enums and private
  fields. Effects describe adapter work; they do not perform it.
- Increment or invalidate request identity before work becomes stale. A result
  commits only when its identity matches the authoritative pending state.
- Add an adapter trait only when a real external dependency and a deterministic
  second implementation both exist.

## Validation

Apply [the automated testing standard](../../docs/testing-standard.md). Test
behavior through `dispatch` and `snapshot` in the same change. For changed state
transitions, cover success plus every applicable failure, cancellation/reset,
stale/late completion, saturation/overflow, and idempotence case.

Focused command:

```powershell
.\scripts\test.ps1 -Suite core
```

Update `docs/architecture.md` when the Command/Effect/Snapshot protocol or state
owner changes. Such an ownership change also requires an ADR.
