# Windows platform contract

## Support tier

Windows x64 with the MSVC toolchain is Tier 1 for this repository. Tier 1 means
every change must compile in Windows CI, pass the automated native first-frame
and last-window close smoke, and product releases must pass the specialized
manual checklist on a supported Windows version.

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

`scripts/smoke.ps1` runs two bounded checks against the built executable:

1. The internal `--smoke-test` mode opens the production
   GPUI/gpui-component window, completes a real frame, dispatches the production
   `Increment` Action, verifies its state on the following frame, and removes
   the window. The shared last-window policy requests application quit. Success
   requires exit code zero and the `GPUI_SMOKE_OK` marker.
2. A normal interactive launch waits for a real main-window handle, sends the
   standard main-window close request, and requires the process to exit with
   code zero within 15 seconds.

A timeout terminates only the process started by the script. Together these
checks prove process startup, native window/backend initialization, first-frame
rendering, Action routing, state projection, application-directed last-window
exit, native close routing, and bounded process termination. They do not prove
pixel appearance, DPI behavior, accessibility, packaging, or release subsystem
behavior.

Run it directly with:

```powershell
.\scripts\smoke.ps1
```

The canonical `scripts/check.ps1` builds the Windows target and then runs this
smoke with `-SkipBuild`; CI therefore executes the same path.

## Application exit policy

`app-ui` owns an application-lifetime `on_window_closed` subscription. After
GPUI removes a closed window, the callback checks the authoritative application
window collection and calls `cx.quit()` only when it is empty. The subscription
is retained by an App-global lifecycle owner rather than detached.

This policy makes closing the last window an application contract instead of an
assumption about the current GPUI Windows backend. If the template later owns
resources that require confirmation, drain, flush, join, or cleanup, this quit
request must enter the shared shutdown coordinator before process exit.

## Specialized release checklist

- Process starts without a console window in release mode.
- Main window opens, paints, accepts input, minimizes/restores, and closes.
- DPI and text remain usable at 100%, 150%, and 200% scaling.
- Background work cannot update a closed/replaced entity.
- Closing the last intended window terminates the process and releases native
  resources.
- Installer/uninstaller behavior is verified separately when packaging exists.
