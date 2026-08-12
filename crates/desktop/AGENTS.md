# desktop owner contract

This file extends [the repository contract](../../AGENTS.md) for process startup.

## Owner

`desktop` owns the executable target, Cargo product metadata, Windows ICON and
VERSIONINFO compilation, process-level startup flags, and the call into
`app_ui::run`. It is intentionally thin. Follow
[the product identity contract](../../docs/product-identity.md).

## Boundaries

- Keep product state, GPUI elements, service logic, persistence, and background
  workers out of this crate.
- Keep the release `windows_subsystem = "windows"` behavior unless a documented
  product decision changes console ownership.
- Keep GPUI as the sole application-manifest owner. `build.rs` may embed icon
  and VERSIONINFO but must not embed a second manifest resource ID 1.
- Put Win32/COM or other platform behavior behind an adapter in `app-ui` or a
  dedicated platform crate; do not grow `main.rs` into a second owner.
- A change to process exit or last-window behavior follows the Windows contract,
  updates the lifecycle ledger, and records an ADR when shutdown semantics move.
- Startup, first-frame, or exit behavior also updates and runs the automated
  Windows smoke defined by [the testing standard](../../docs/testing-standard.md).

Focused command:

```powershell
cargo build --package desktop --target x86_64-pc-windows-msvc --locked
```
