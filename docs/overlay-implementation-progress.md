# Overlay implementation progress

Spec: [overlay-gpui-spec.md](overlay-gpui-spec.md). Baseline commit:
`03c0e72` on `dev/gpui_overlay_component`; initial worktree clean.

## Current status (2026-09-22)

Runtime DPI switching is fixed and manually accepted: with Overlay attached to
Settings, the user changed 100% → 150% → 100% without dragging; Overlay adapted
automatically. See [DPI evidence](overlay-dpi-evidence.md) for diagnosis and the
focused regression. Temporary diagnostics were removed. The user also reports
cross-screen and multiple-desktop checks passed. The user subsequently constructed
a negative-coordinate display scenario and confirmed interaction and functionality
passed (2026-09-22). The manual environment checklist is now accepted; unified
regression remains deferred. These are user-reported results, not automated evidence.

The user accepts the 60 Hz item by manual acceptance: both current displays
are reported as 60 Hz, functionality is normal, and no further refresh-rate
coverage is requested. Historical timing samples passed their thresholds but
did not record the window's monitor/refresh rate; this acceptance does not
retroactively certify their monitor attribution. No further 60 Hz test is due.

The user also confirmed all three manual workflow checks passed: content
retention across HUD/Interactive switches, hide/restore alignment, and host
switching/host-close/control-window-close without residual overlays. This is
user-reported acceptance on the current environment; it does not certify the
other display-environment requirements beyond the separately recorded evidence.

User-reported manual acceptance: clipboard copy/delete/paste comparison passed
without issues in ordinary preview and Interactive Overlay. This is manual
evidence, not an automated OS-clipboard test. The user requested that unified
regression not run for now; stage-wide repository/generated gates stay pending.
The remaining user-facing checklist is [manual acceptance](overlay-manual-acceptance.md).

Component-acceptance continuation (work in progress): the native IME comparison
now additionally sends Tab then Shift+Tab after commit and observes focus leave
and return in both containers without changing the text. The new assertion
first failed without those keys (`target/focus-red.log`), then passed with real
guarded input (`target/focus-green.log`). Remaining component acceptance is
grouped into one stage. Both review axes have completed without remaining
actionable findings; unified regression is deferred at the user's request.

The independent `-Suite components` now passes in both containers, with actual
clicks and observable Dialog/Sheet open-close transitions, menu count reset and
notification creation. Overlay remains Interactive throughout component Escape.
The test initially exposed a fixture-only recursive Root borrow; observing
through AnyWindowHandle avoids borrowing the Root entity. A wrong menu-item
coordinate then failed the reset assertion and was corrected from the screenshot.
No business behavior was changed. Default gates now include this suite.
Visual inspection confirmed the same tooltip and a wheel movement from list
items 01–04 to 09–12 in both containers:
[preview tooltip](overlay-evidence/probe-components-preview-tooltip-200.png),
[overlay tooltip](overlay-evidence/probe-components-overlay-tooltip-200.png),
[preview scroll](overlay-evidence/probe-components-preview-scroll-200.png),
[overlay scroll](overlay-evidence/probe-components-overlay-scroll-200.png).
These are visual evidence for the current 200% desktop, not screenshot assertions.

Menu Escape/reopen and notification close-button input now pass natively in
both containers (`target/components-final.log`), with an eight-second observation
window and a required notification present-to-absent transition. Strict Clippy
passes. Native resources return to zero and both processes complete cleanup.
Review follow-up confirmed that locked `gpui-base 0.6.4` Popover trigger mouse
down invokes `toggle_open`, whose transition uses `!self.open`. The menu
Escape/reopen assertion therefore matches the current component contract.
An omitted-Escape native negative control failed specifically with
`reset_seen: false` (`target/components-menu-negative.log`). The source was
restored byte-for-byte in `finally` and the fixture rebuilt; the negative-control
change is not part of the delivered source.

Real Microsoft Pinyin comparison now passes on the current 200% desktop in
both ordinary preview and Interactive Overlay. Guarded virtual-key input opens
two observed composition sessions: Escape cancels the first, Space commits
`你好` from the second. The overlay remains Interactive and never reports hidden
after composition begins; it subsequently returns to HUD with click/wheel
passthrough and zero native resources after cleanup. This mode does not use
Unicode packet injection or change the user's input-method settings.
Evidence: [ordinary composition](overlay-evidence/probe-ime-preview-composition-200.png),
[overlay composition](overlay-evidence/probe-ime-composition-200.png),
[ordinary commit](overlay-evidence/probe-ime-preview-input-200.png),
[overlay commit](overlay-evidence/probe-input-200.png).
Use `-IncludeIme` on both full gate scripts to include this environment-dependent
suite; default gates do not claim IME acceptance. Both full gates passed with
`-IncludeIme`, including generated-project Release resource checks (fixture
`5cf62bc4`). Standards and Spec reviews each found one acceptance issue, now
fixed and re-reviewed: non-Chinese keyboard layout is an environment error,
and final acceptance requires no remaining composition range. The active TSF
profile and Chinese/English mode remain documented manual prerequisites; the
layout check alone cannot certify them. Both axes have no remaining findings.

The new `smoke-overlay.ps1 -Suite fallback` deliberately discards WinEvent
callbacks in the native probe's `test-support` build. The default production
build does not compile this environment switch or discard callback. The real
watcher, 250 ms sampling loop, GPUI driver and native apply path are unchanged.
Acceptance requires four changed move/resize samples plus hide/restore within
500 ms total per operation, <=1 px alignment, a positive discarded-event count,
normal cleanup and successful process exit. The first focused run discarded
6 events and converged in roughly 248–264 ms; hiding took 264 ms.
A negative control temporarily removed periodic sampling: the same native test
failed at its 500 ms bound. Source was restored in `finally` and checked before
the positive full-gate rerun. Both review axes found no actionable issue.
The full repository gate passed with 8 discarded events. Its
[stored samples](overlay-evidence/fallback-200.json) record
move/resize times 186.787–263.324 ms, hide 263.447 ms
and restore 259.522 ms, with zero resources after cleanup. The discarded-event
count is verified in the process log; the JSON stores the timing samples.
Generated-project canonical and Release-resource verification also passed.

The native geometry suite now includes real DWM cloak/uncloak and Win+Left Snap.
The cloak test checks the [documented DWM state](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute),
requires host foreground and WS_VISIBLE to remain unchanged, observes overlay
hiding within a total 500 ms, then restores the host and checks visible alignment.
Focused runs passed (first cloak-to-hidden observation: 258.442 ms).
Snap uses guarded SendInput on the fixture host, verifies half-work-area placement,
allows the shell's animation/Snap Assist to settle, then reactivates only the
fixture and asserts <=1 px alignment within 100 ms. It does not claim the entire
Win+Left animation takes <=100 ms. The first run exposed the fixture's premature
foreground assumption; checking actual foreground fixed it without relaxing the
overlay alignment bound. JSON now records cloak latency and Snap completion.
This does not replace deliberately dropping WinEvent notifications to prove the
fallback path. The main repository gate passed with cloak-to-hidden 260.809 ms
and Snap alignment within one physical pixel. Generated-project canonical and
Release-resource checks also passed, including the final environment-error
classification fix. Standards and Spec reviews reported no remaining actionable
finding after that fix. Native code remains entirely in the adapter.

After the user confirmed an unlocked desktop, native testing resumed on
`5c0a8ea`. The focused HUD/Interactive suite passed, followed by the complete
generated-project check: 38 tests, 100 lifecycle cycles (21.65 seconds), all
close cases, real input, geometry, mutable product identity and Release resource
inspection. The generated geometry P95 was 3.908 ms (32 samples, maximum
4.948 ms), with all observed edges within one physical pixel. Controlled evidence
was successfully preserved under `target/generated-overlay/gpui fixture c729c6b5/`.
This clears the current foreground environment blocker. The earlier empty-text
failure did not recur in three input runs; its root cause remains unproven.
The main-repository gate also passed on the same revision: 100 cycles in
21.83 seconds, successful native input, geometry P95 3.832 ms (maximum 4.529 ms),
and completed cleanup with resource counts at zero. All native checks listed as
uncompleted below still require their own evidence.

Latest continuation: component comparison exposed and fixed a production bug:
Sheet's Cancel closes the sheet but propagates, so the same Escape also requested
HUD mode. A failing test first proved this in overlay while ordinary preview
worked. Capture now remembers active Sheet/Dialog/composition before component
handlers run; fallback respects that event's prior state. No business callback,
dependency change or native call was added. Sheet/menu Escape, notification
creation and normal animated clearing now pass in the shared-content comparison.
Tab/Shift+Tab focus traversal and select/copy/delete/paste also pass through
production keyboard Actions in both containers, using the test platform clipboard.
These remain headless evidence, not Windows IME or OS clipboard acceptance.

After this fix, strict Clippy and all 38 tests passed. `scripts/check.ps1` passed
its code/build/product checks, original native smoke, 100 lifecycle cycles
(22.0 seconds), and all three native close scenarios with resources at zero;
it then stopped on `PROBE_ABORTED` because the HUD fixture could not obtain
foreground. Full native input/generated validation remains pending. The two-axis
review found no actionable Standards or Spec issue in the Sheet fix.

The reusable overlay module, host selector, shared business content and lifecycle
implementation are committed in `5f59181`. Stage 3 native acceptance is still in
progress; the goal is not fully accepted. Earlier entries below are historical
checkpoints, not the current result.

- The user explicitly deferred 100%/150% scaling, negative-coordinate monitors
  and cross-monitor checks. Keep these **uncompleted**, not passed or removed
  from the spec. Current native evidence is at 192 DPI (200%).
- The interactive-desktop restriction was resolved by running controlled native
  tests in the interactive session. Foreground and target-process safeguards
  remain enabled. Both HUD and Interactive smoke now pass with actual SendInput:
  opaque HUD content passes one click and wheel to the external host without
  activation; Interactive increments the production button, enters `test`, then
  switches back to HUD and passes the next click/wheel to the host.
- The input failure was a fixture hit point inside the input's outer frame.
  Moving it to the measured editor center made several native runs pass. A later
  generated-project run still failed with count 1 and empty text, so this is
  **not yet a proven complete fix**. UTF-16 Unicode
  packet input avoids keyboard-layout dependence; it does **not** prove Chinese
  IME composition, physical-key editing or clipboard behavior.
- Screenshots capture only the controlled host client area. Lossless PNG copies:
  [HUD](overlay-evidence/hud-200.png),
  [Interactive input](overlay-evidence/input-200.png),
  [returned HUD](overlay-evidence/switched-200.png).
  Visual inspection confirms the real green host through transparent regions,
  readable `test`, count 1 and no native overlay frame or black background.
- Native geometry covers 32 changed position/size samples, maximize/restore,
  minimize/hide/reappear and a foreground owned host popup. Every observed edge
  must be within one physical pixel; each sample has a 100 ms bound and P95 a
  50 ms bound. JSON stores all sorted samples and the **asserted error bound**,
  rather than pretending the bound is a measured maximum.
  Latest repository run: [32 raw samples](overlay-evidence/geometry-200.json),
  P95 4.009 ms, maximum 4.062 ms; minimize/hide observations 12.942/29.280 ms.
- Timing is measured from immediately before fixture SetWindowPos until its
  observer sees overlay alignment. It includes the host operation and observer
  scheduling; it is not the demo's sample-to-apply counter or a WinEvent timestamp.
  The tested desktop reports 3840x2160 at 144 Hz through GameViewer Virtual
  Display Adapter. Windows 11 Enterprise 26100, i7-13700, RTX 4060 Ti are present.
  This is not evidence for the spec's ordinary 60 Hz desktop requirement.
- The whole repository gate and generated-project initialization, canonical
  checks, mutable identity and Release resource verification passed. A generated
  project failure exposed a missing screenshot output directory; the fixture
  now creates it. After the final review fixes, the repository gate passed again:
  38 tests, all native suites, 100 cycles in 21.6 seconds and zero remaining
  workers/hooks/bindings. The latest generated-project repeat then failed at
  Interactive input (count 1, empty text); its later Release stages did not run.
  Keep the earlier generated Release pass separate from this latest failure.
- Final Standards review found geometry environment failures misclassified as
  product failures. Final Spec review found a late successful observation could
  bypass the time limit. Both were corrected; a regression test now rejects a
  successful predicate observed after its deadline. No production requirements
  or acceptance thresholds were weakened. Both review agents rechecked their
  fixes and reported no remaining actionable findings on their respective axes.

Current diagnosis: distinguish a layout-dependent click miss, delayed input
focus and Unicode/IME handling. Probe failure now reports logical input focus.
Generated-project cleanup preserves controlled screenshots/geometry under
`target/generated-overlay/<fixture-name>/` before removing the temporary copy.
Two subsequent native attempts were blocked before input by foreground guards
(direct launch and the formal hidden-process script). Neither reproduced nor
disproved the empty-text failure. The user has been asked for an unlocked,
undisturbed desktop interval; no safeguard was bypassed.

Still uncompleted: user-deferred DPI/multi-monitor display cases and the current
stage's unified gates deferred at the user's request. The 60 Hz item has been
accepted manually by the user as recorded above. Missed move/resize/hide/restore notifications are covered by
the dedicated native fallback suite above.
Existing headless component/lifecycle tests do not replace those native checks.

Run `cargo run --locked -p desktop -- --overlay-demo`. Refresh/select an external
ordinary window, attach, return to that host and move/resize it; use Interactive
to edit content, then Esc to return to HUD. Closing the external host or the
control window must remove the overlay and release its native resources.
Automated suites: `scripts/check.ps1`, `scripts/test-generated-project.ps1`, or
focused `scripts/smoke-overlay.ps1 -Suite input` / `-Suite geometry`.

## Historical stage 1 checkpoint

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
