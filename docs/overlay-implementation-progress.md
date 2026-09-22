# Overlay implementation progress

Spec: [overlay-gpui-spec.md](overlay-gpui-spec.md). Baseline commit:
`03c0e72` on `dev/gpui_overlay_component`; initial worktree clean.

## Current stage

Stage 1 feasibility plus the first Stage 2 public API/lifecycle path. Not a
completed implementation; no local commit has been made yet.
Use the user-requested implement skill for every stage: focused compile/test
loops, code-review after implementation, local commits.

- Added the adapter crate, GPUI bridge, real transparent Kit Root / Surface,
  ordinary input/button/dialog content, and external controlled host examples.
- `cargo build -p app-ui --example overlay-probe -p overlay-win32 --example fixture --locked --offline` passes.
- Real interactive desktop HUD probe: opaque GPUI content renders, transparent
  area shows the green fixture, no native overlay border; SendInput at the
  opaque button reaches host (1 click, 1 wheel), foreground stays host.
- Interactive probe: same real button reports `PROBE_BUTTON count=1`; host
  receives 0 clicks / 0 wheels and overlay receives foreground.
- Current machine probe reports physical 700 x 460 / GPUI 350 x 230 (200%).
- Screenshots currently in ignored `target/probe-hud.bmp` and
  `target/probe-interactive.bmp` (PNG copies also available).
- Real keyboard input through SendInput virtual keys writes `test`. Initial
  Unicode-packet injection did not; do not confuse that probe failure with
  ordinary keyboard input. Allow mouse focus to settle before sending keys.
- A real Kit dialog rendered successfully (target/probe-dialog.png from the
  early test); raw title-root lookup was true. Latest fixture coordinates after
  client-area alignment need fixing so this becomes an assertion, not a log.
- In-place interactive -> HUD preserved count 1 and input model `test`, then
  fixture received click/wheel with host foreground; process exited 0.
  The screenshot's input text is white-on-white due to probe content styling;
  fix the content foreground color before treating visual input as accepted.
- Native apply now samples host physical client rect; at 200% actual rect
  (93,138)-(887,667) maps to GPUI 397 x 264.5. Other DPI/cross-screen cases are
  still unverified.

## Stage 2 code and verification

The public facade now has host discovery/resolve tasks, open_window, cloned
content/update/snapshot/observe/mode/close handles, Entity session events,
App-global Runtime and prepare_quit. The native adapter has PID/TID/generation
identity, bounded caption enumeration, DPI-scoped geometry, visibility,
per-session WinEvent worker/latest slot, explicit stop/join, subclass liveness
and mouse activation policy. This is an initial implementation, not final QA.

`overlay/probe.rs` now uses the production public API rather than its earlier
standalone binding. The real probe confirms Attaching -> Ready (hidden when
background) -> ModeChanged -> Closing -> PROBE_CLEANUP_COMPLETE -> exit 0.
Latest public-API input runs were safely aborted because the desktop foreground
changed and Windows refused SetForegroundWindow; earlier raw feasibility input
evidence does not automatically prove this newer path's full behavior.

Five production-facade GPUI tests pass using the internal native bridge test
adapter (cfg(test), explicit App global): last handle drop, owner removal /
content release, late Closed observation exactly once, failed mode preserving
content, old generation terminal rejection, and quit barrier. The mode test
also now exercises retry: initially failed red (Interactive vs Passthrough),
then passed after resetting desired mode on native failure. A single test
contains several related assertions; there are five test functions total.

Latest checks:

- `cargo check -p app-ui --all-targets --locked --offline`: passed before latest
  tests/formatting.
- `cargo test -p app-ui --features test-support --locked --offline overlay::tests -- --nocapture`:
  5 passed; then extended retry case run alone red -> green.
- `cargo clippy -p overlay-win32 -p app-ui --all-targets --locked --offline -- -D warnings`:
  passed after latest formatting fixes.
- Full gate / generated-project / code-review have NOT run.

Second important finding: GPUI defaults to QuitMode::LastWindowClosed on
Windows, independently of our policy observer. Runtime init now sets
QuitMode::Explicit, or the foreground executor exits before background join
can report completion. Third: use AnyWindowHandle.update to call WindowExt;
WindowHandle<Root>.update already borrows Root and causes a nested update panic
when closing dialogs. Both fixes are now in production code.

Critical implementation finding: apply native SetWindowPos outside a borrowed
GPUI App/Window update closure. Synchronous WM_SIZE callbacks otherwise cannot
update the borrowed GPUI window, leaving the scene empty. A foreground Task
without an active cx.update borrow resolves this; no dependency fork needed.
Windows PopUp creation with style zero also gets native decoration; explicitly
set the overlay's own style to WS_POPUP before first show.

Sandbox desktop returned GetForegroundWindow == 0. Real desktop probes use
approved escalated execution and only operate fixture/probe windows. Do not
interpret sandbox input failure as a rendering defect.

## Remaining work

1. Harden acceptance probe/fixture: fail nonzero on missing expected behavior,
   bounded process cleanup on every setup failure; never send input to a user
   window (recheck target before every input stage). Capture only fixture region.
   Verify complete stage 1 including other DPI/multi-monitor availability.
2. Finish module details BEFORE demo: Esc uses normal bubbled Kit Cancel action
   after component handling; avoid swallowing IME-cancel Escape. Surface needs
   weak session/focus and internal input cleanup. Preserve logical focus across
   hide, restore after mode changes, dismiss menus/layers, cancel native capture/
   IME and pending keys. Add focus-return advisory on HUD transition. Identify
   same-overlay-thread IME helper foreground without treating host dialog as
   eligible. Current mode cleanup closes dialog/sheet and blurs but is incomplete.
3. Native hardening: transactional rollback if SetWindowPos/style change fails,
   check unhook/unsubclass cleanup failures; enforce generation/sequence in apply;
   stop/join accounting and 2-second cleanup reporting; avoid polling full native
   sample on UI except final transaction checks; skip unchanged moves. Add
   non-Windows UnsupportedPlatform stubs (currently app-ui won't compile there).
   Ensure callback lifetime is safe if subclass removal fails. Apply currently
   stores a Box callback state and native destruction marker; Drop removes it.
4. More GPUI facade tests: close before Ready, content.remove_window, duplicate
   host / invalid owner / overlay owner, once-only build and Entity identity,
   successful rapid modes, native setup / tracking errors and release, input /
   layered Root components. Fake native bridge is enum-based and watches can
   accept injected snapshots; production paths share driver/session code.
5. Demo, CLI mode routing, full fixture and architecture checks / fixtures,
   documentation and ADR, full check + generated project, two-axis code-review,
   local commits and runnable acceptance evidence.

The existing architecture scripts still only inspect three workspace members;
must extend to all members with the explicit adapter unsafe exception and
positive/negative fixtures. Cargo.lock only added local adapter dependencies;
GPUI/Kit versions remain unchanged. App lifecycle now calls overlay init and
prepare_quit; default template and original smoke need regression checks.

Skills read: implement (user path outside listed catalog), sdk-change-safety,
tdd plus tests/mocking references, and code-review. Code-review requires two
parallel review agents when ready (explicit skill authorizes those agents,
not implementation delegation). Use baseline 03c0e72 and provided spec; user
already authorized the implementation and repository-required local commits.

Do not report the spec fulfilled based on these initial probe results.

## Latest continuation checkpoint

Subsequent work supersedes some outstanding items above:

- Surface now has its own focus context and weak Session. Normal Kit Cancel and
  Input Escape bubble to HUD fallback; capture-phase composition inspection uses
  `WindowExt::focused_input` + `EntityInputHandler::marked_text_range`. This is
  needed because Kit's Input Escape unmarks composition then propagates. Root
  helpers also unmark composition, close dialog/sheet/notifications, stop active
  drag and blur (which clears GPUI pending keystrokes). Saved focus is restored
  on interactive return/visibility recovery. Persistent mouse pressed/element
  interaction state and menu cleanup still need a focused regression test.
- 11 overlay GPUI tests passed together after cleanup timeout integration.
  Added business remove_window, close-before-Ready, duplicate host/overlay owner,
  bubbled cancel, dialog-consuming cancel and composition-first Escape tests.
  Composition test dispatches Kit Input Escape (different Action from dialog
  Cancel); marked composition survives only until the first Escape and the
  second switches to HUD. Test-only adapter uses production driver/session.
- Native focus-return is a single attempt only when overlay owns foreground;
  refusal is a nonfatal OperationFailed diagnostic. Narrow same-thread IME /
  MSCTFIME UI foreground eligibility was added (still needs real IME QA).
- Native apply rejects another generation, ignores late sequence/terminal
  reuse, skips unchanged positions after checking actual HWND bounds, and uses
  a DPI scope across the transaction.
- Native callback ownership changed from Box to Rc with one native-owned raw
  reference: normal unbind releases it, NCDESTROY releases it, and failed
  unbind retains it until destruction rather than risking a dangling callback.
  Removal failure currently logs only; improve typed failure reporting.
- Foreground cleanup now awaits a background join via bounded completion slot,
  reports OperationFailed after 2 seconds, and continues waiting without false
  Closed/forced release. Native cleanup complete marker was observed in the
  production probe after QuitMode::Explicit fix.
- Non-Windows unsupported module exists with explicit failing discovery and
  native operations; cross-target compilation has NOT been run. Its current
  NativeError compatibility shim should be reviewed for API quality; bridge
  binding currently maps it to NativeSetupFailed instead of UnsupportedPlatform.
- Architecture checker now traverses all workspace packages, permits only the
  adapter's explicit deny + scoped unsafe exception, and enforces native bridge
  / source isolation. UiDependencies and positive/negative fixtures expanded.
  Both `scripts/test-ui-dependencies.ps1` and `scripts/check-architecture.ps1`
  passed. These extend allowed structure without weakening Kit/domain isolation.
- Latest `cargo check -p app-ui --all-targets --locked --offline` passed after
  callback lifetime fix and formatting. Clippy passed earlier; subsequent new
  style warnings were auto-fixed by `cargo clippy --fix --allow-dirty ...`, then
  `cargo fmt --all`. Re-run strict Clippy after further changes.

Next work: finish native transactional rollback and cleanup/error accounting,
focused input/focus/pressed-state regressions and fixture assertions; then demo
and CLI, proper native smoke + 100-cycle/resource/geometry/latency evidence,
docs/ADR, full gate/generated fixture and two-axis review. No local commits yet;
do not deliver as complete. Last git diff --check passed before these additions.

## 2026-09-22: module/demo milestone and review fixes

This checkpoint supersedes the older next-work lists above. The complete spec
is **not yet accepted**; native visual/input and hardware evidence remains open.

- Added `--overlay-demo` with conflicting internal-mode rejection, asynchronous
  host discovery/filter/keyboard selection, selected-versus-attached state,
  replacement after old Closed, HUD/Interactive switching and ordinary preview.
  Shared DemoContent has buttons/actions, input, switch, scrolling, tooltip,
  menu, dialog, sheet, notification, corner markers and synchronization metrics.
- Native mode changes roll back both styles on failure; rollback failure poisons
  the binding and hides it. Explicit unbind failure reaches terminal diagnostics.
  Worker/hook/binding counters support per-cycle native resource assertions.
- Added failure-path tests for native bind/start/mode and cleanup; terminal host
  events, content factory identity across mode/hide, and late updates. Pointer
  capture is released on suspension. Owner-close cleanup completes in the test
  executor without advancing a polling timer.
- The driver now waits on a bounded coalescing notification, shared with native
  snapshots and session commands. The native thread waits for messages or its
  250 ms fallback deadline, retaining a 16 ms sampling cap during event bursts.
  Shutdown posts to its initialized message queue. Cleanup awaits the background
  Task directly, reporting at two seconds while retaining the same join task.
  GetClientRect, ClientToScreen and hook setup errors retain native error codes.
- Shared-content tests exposed missing initial Action focus, then verified the
  same real Button/input/Dialog/Escape interactions in ordinary and overlay
  windows after adding a normal business focus context. A second red/green case
  proved blur alone leaves Kit menus open; suspension now dispatches the popup's
  normal Cancel synchronously, restricted to its popup key context.
- `code-review` ran separate Standards and Spec agents against baseline 03c0e72
  plus all new files. Standards found no actionable violations. Spec found four
  issues (pointer capture, delayed owner hide, idle polling, missing native
  codes); all were fixed and the Spec agent re-reviewed them without a remaining
  actionable finding. This source review does not certify manual acceptance.
- Added `scripts/smoke-overlay.ps1` to the canonical gate. Ordinary input smoke
  retains 15 seconds; separate 100-cycle endurance allows 60 seconds total. The
  original 15-second whole-endurance experiment failed at about 60 windows;
  timing showed ~170 ms spent creating each GPUI window. The endurance bound
  separates that cost from the spec's ordinary process-exit smoke deadline.
  Every cycle still requires Closed once, content release and resource baseline.
- Formal x64 endurance passed repeatedly. Latest after event-driven cleanup:
  100 cycles in 22.8 seconds, workers/hooks/bindings all zero. The generated
  Unicode/spaced-path product also passed 100 cycles in 22.7 seconds.
- `scripts/check.ps1` passed formatting, strict Clippy, workspace tests,
  documentation/validator/architecture checks, Windows build/product identity,
  original first-frame/last-window smoke, and native overlay endurance. It then
  **failed** the overlay input smoke because the controlled host could not gain
  foreground. This is recorded as an environment failure, not skipped or passed.
- `scripts/test-generated-project.ps1` passed initialization, Unicode identity,
  generated canonical checks through the same stages, then **failed** at the
  same input foreground guard. Its later mutable identity/Release stages have
  not run. An earlier attempt also caught unformatted new code; formatting was
  fixed before the second attempt.
- The input fixture now checks controlled-process foreground before each input
  batch and rejects unrelated occlusion. It verifies actual host click/wheel
  counts, GPUI content changes and the switch back to HUD. Current DemoContent
  native coordinates are based on measured headless bounds; real desktop
  revalidation remains required. Screenshots and input are never treated as
  proven solely by headless tests or the earlier feasibility probe.

Still required: actual current-demo HUD/Interactive input and visual smoke;
100%/150%/200%, negative-coordinate and cross-monitor evidence; native geometry
and event-to-apply P95 measurements; host visibility/dialog/Snap scenarios;
ordinary-vs-overlay IME/clipboard/Tab/tooltip/scroll/layer comparison; final full
gate and generated Release stages; final reviewed local delivery commits.
The user was asked asynchronously for an unlocked interactive desktop window;
no answer had arrived at this checkpoint. Do not bypass the foreground guard.

Additional verified results before the implementation milestone commit:

- Native `--host-exit`, `--owner-close`, and `--external-close` scenarios now run
  in the formal lifecycle suite. All three passed with one terminal event,
  released content and worker/hook/binding counts at zero. Host destruction
  retained `HostGone`; the two controlled native close cases completed normally.
- The latest whole-workspace run had 37 passing tests (4 core, 29 UI, 3 desktop,
  1 adapter signal test). Latest strict Clippy, architecture, document links and
  diff whitespace checks passed. Final lifecycle suite, including the new close
  scenarios, passed; its 100-cycle run took 22.0 seconds.
- The probe now requires visible foreground state in addition to its frame
  callback, and the script requires the fixture's real-input success marker.
  An invisible background frame therefore cannot produce input acceptance.
- A local implementation milestone is ready to commit; this does not change
  the outstanding acceptance items above or certify the complete goal.
