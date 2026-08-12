# Windows platform contract

## Support tier

Windows x64 with the MSVC toolchain is Tier 1 for this repository. Tier 1 means
every change must compile in Windows CI, pass the automated native first-frame
smoke, and product releases must pass the specialized manual checklist on a
supported Windows version.

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

## Automated native smoke

`scripts/smoke.ps1` starts the built executable with the internal
`--smoke-test` mode and a 15-second process deadline. The application opens the
production GPUI/gpui-component window, completes a real frame, dispatches the
production `Increment` Action, verifies its state on the following frame,
removes the window, and quits. Success requires both exit code zero and the
`GPUI_SMOKE_OK` marker; timeout terminates only the process started by the script.

This proves process startup, native window/backend initialization, first-frame
rendering, Action routing, state projection, and bounded close/exit. It does not
prove pixel appearance, DPI behavior, accessibility, packaging, or release
subsystem behavior.

Run it directly with:

```powershell
.\scripts\smoke.ps1
```

The canonical `scripts/check.ps1` builds the Windows target and then runs this
smoke with `-SkipBuild`; CI therefore executes the same path.

## Specialized release checklist

- Process starts without a console window in release mode.
- Main window opens, paints, accepts input, minimizes/restores, and closes.
- DPI and text remain usable at 100%, 150%, and 200% scaling.
- Background work cannot update a closed/replaced entity.
- Closing the last intended window terminates the process and releases native
  resources.
- Installer/uninstaller behavior is verified separately when packaging exists.
