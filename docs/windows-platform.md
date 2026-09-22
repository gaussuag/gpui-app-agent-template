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
- Keep HWND and COM apartment ownership explicit, including thread affinity and
  release paths; document cross-owner cleanup when it is not evident in code.
- Surface recoverable native failures as user-visible state with an action the
  user can take.

The overlay implementation uses `overlay-win32/src/windows` for every native
operation and fixture helper. `app-ui::overlay::native_bridge` is its only GPUI
caller. The adapter temporarily enters PerMonitorV2 thread DPI context around
physical-coordinate operations and restores it afterward. Borrowed HWNDs do
not convey destruction authority. The session coordinator owns stop/unbind/
background-join ordering; see [ADR 0009](decisions/0009-native-overlay-lifecycle.md).

## Product resources

The desktop Cargo manifest, `crates/desktop/build.rs`, and the fixed
`resources/windows/app.ico` path own product identity and static PE resources.
Resource compilation fails the Windows build on missing/invalid metadata or
icon. GPUI remains the sole application-manifest owner; do not add a second
manifest through `winresource`. Run `scripts/check-product.ps1` to inspect PE
VERSIONINFO, an extractable icon, and manifest resource ID 1. Release profile
also requires a configured publisher and a non-template icon. The complete
field map is in [the product identity contract](product-identity.md).

## Automated native smoke

Before changing main-window startup error propagation or interactive process
exit status, read [the startup failure baseline](architecture.md#startup-failure-baseline).
The smoke below proves successful native startup and rejects an early process
exit; it does not inject platform window-creation failure.

`scripts/smoke.ps1` runs two bounded checks against the built executable:

1. The internal `--smoke-test` mode opens the production
   GPUI Kit window, completes a real frame, dispatches the production
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

`scripts/smoke-overlay.ps1` also runs from the canonical gate. Its controlled
external host records real system click/wheel delivery while a separate GPUI
process uses production overlay content. HUD and Interactive probes have
15-second deadlines, require a visible frame, and require complete cleanup.
Each input batch checks the foreground and target process; an unavailable or
occluded desktop is an environment failure, never a passing input result.
The separate `-Suite lifecycle` run attaches/detaches 100 times in at most
60 seconds and checks content release, terminal events and worker/hook/binding
counts after every cycle. Screenshots are saved under `target/probe-*.bmp`.
The lifecycle suite also closes the real host, the native owner window and the
native overlay window in separate bounded runs, checking terminal diagnostics
and resource release through the production facade.
These checks do not replace the spec's 100%/150%/200% and cross-monitor visual,
IME, clipboard, or measured drag-latency acceptance evidence.

## Application exit policy

`app-ui` owns an application-lifetime `on_window_closed` subscription. After
GPUI removes a closed window, the callback checks the authoritative application
window collection and calls `overlay::prepare_quit` when it is empty. The subscription
is retained by an App-global lifecycle owner rather than detached.

This policy makes closing the last window an application contract instead of an
assumption about the current GPUI Windows backend. The coordinator waits for
overlay cleanup before its completion callback calls `cx.quit()`. Explicit quit
mode prevents backend auto-exit from bypassing that wait.

## Specialized release checklist

- Process starts without a console window in release mode.
- Main window opens, paints, accepts input, minimizes/restores, and closes.
- DPI and text remain usable at 100%, 150%, and 200% scaling.
- Background work cannot update a closed/replaced entity.
- Closing the last intended window terminates the process and releases native
  resources.
- Installer/uninstaller behavior is verified separately when packaging exists.
- ProductName, FileDescription, CompanyName, copyright, versions, filename,
  icon, PerMonitorV2, and Common Controls v6 match the configured product.
