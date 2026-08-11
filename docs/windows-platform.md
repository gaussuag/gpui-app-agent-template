# Windows platform contract

## Support tier

Windows x64 with the MSVC toolchain is Tier 1 for this repository. Tier 1 means
every change must compile in Windows CI and product releases must pass a manual
open/render/input/close smoke test on a supported Windows version.

This is a repository-owned tier. GPUI is pre-1.0, so upstream backend presence
or another application's Windows build is not sufficient evidence for this
project.

## Required environment

- Rust toolchain and target from `rust-toolchain.toml`.
- Visual Studio Desktop development with C++.
- A current Windows 10/11 SDK.
- PowerShell capable of running the scripts in `scripts/`.

## Native integration rules

- Isolate Win32/COM code in a platform module under `app-ui` or a dedicated
  adapter crate; domain crates remain portable.
- Document every `unsafe` block with its memory, thread, handle, and lifetime
  invariants. The workspace forbids unsafe by default, so a narrowly scoped
  platform crate needs an explicit reviewed exception.
- Keep blocking registry, filesystem, shell, device, and network operations off
  the GPUI foreground thread.
- Treat HWND and COM apartment ownership as lifecycle resources and add them to
  the lifecycle ledger.
- Surface recoverable native failures as user-visible state with an action the
  user can take.

## Release smoke checklist

- Process starts without a console window in release mode.
- Main window opens, paints, accepts input, minimizes/restores, and closes.
- DPI and text remain usable at 100%, 150%, and 200% scaling.
- Background work cannot update a closed/replaced entity.
- Closing the last intended window terminates the process and releases native
  resources.
- Installer/uninstaller behavior is verified separately when packaging exists.
