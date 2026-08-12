# Rust + GPUI automated testing research

## Purpose and evidence boundary

This note extracts the smallest reusable testing system from the 18 fixed-SHA
projects studied in `report-awesome-gpui`. It is an implementation input for
this template, not a claim that any referenced project currently passes its
tests.

The research inspected test source and CI configuration but did not execute the
18 upstream repositories. Therefore:

- “test source exists” does not mean the fixed SHA passes;
- a workflow file does not prove a job ran or passed;
- a build, headless test, first-frame smoke, package test, and visual review are
  different evidence;
- test counts are inventory signals, not proof that important behavior is
  covered.

First-party source is cited at an immutable commit. GPUI API facts are checked
against the locally resolved `gpui 0.2.2` crate at
`C:\Users\gaosi\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\gpui-0.2.2`.

## Conclusion

The common, practical design is a six-layer test stack:

1. pure `app-core` state and policy tests;
2. fake-adapter tests for fallible external boundaries;
3. headless GPUI Entity, Action, focus, and render tests;
4. deterministic async, stale-result, cancellation, and lifecycle tests;
5. a minimal native Windows first-frame/start-action-close smoke;
6. CI that runs each applicable layer and reports exclusions explicitly.

The central rule is not “every change adds a UI test”. Every behavior change
adds the cheapest test that can observe its contract, and every changed
entry-to-result chain must account for success, failure, cancellation, late
completion, and shutdown where applicable. Pure policy stays below GPUI;
GPUI tests prove adapter and interaction behavior; a native smoke proves only
that the packaged platform path can start, draw, act, and stop.

## What the 18 projects actually teach

| Project | Reliable testing lesson | Limit that must not be copied |
|---|---|---|
| Zed | Inject filesystem, HTTP, clock, executor, and install behavior; drive real GPUI context for observable UI chains. [ProjectPanel `FakeFs` test](https://github.com/zed-industries/zed/blob/c6b01d8a203a6dc8c06a89e05ee4dec69de55cf0/crates/project_panel/src/project_panel_tests.rs#L117-L172), [updater fake HTTP/clock/install tests](https://github.com/zed-industries/zed/blob/c6b01d8a203a6dc8c06a89e05ee4dec69de55cf0/crates/auto_update/src/auto_update.rs#L1362-L1468) | Its scale-specific harness is not a prerequisite for a new app. Adopt the seams, not the whole infrastructure. |
| gpui-component | Test pure parsing/theme logic and stateful components separately; exercise Entity state and bounded async stream behavior. [Select tests](https://github.com/longbridge/gpui-component/blob/26cc9366abb27ccedce386ac99a615a8fa7018da/crates/ui/src/select.rs#L802-L894), [TextView async tests](https://github.com/longbridge/gpui-component/blob/26cc9366abb27ccedce386ac99a615a8fa7018da/crates/ui/src/text/state.rs#L725-L825) | Programmatic state tests alone do not prove pointer, keyboard, focus, accessibility, or visual behavior. |
| DBFlux | Combine temporary SQLite with `TestAppContext`; keep request construction and fallback rules independently testable. [GPUI/read-only tests](https://github.com/0xErwin1/dbflux/blob/3b425f92a4214ecf877b4d85abc2ec045cc050fb/crates/dbflux_ui_document/src/code/mod.rs#L1724-L1865), [execution policy tests](https://github.com/0xErwin1/dbflux/blob/3b425f92a4214ecf877b4d85abc2ec045cc050fb/crates/dbflux_ui_document/src/code/execution.rs#L1914-L2055) | A temporary database does not prove live drivers, graphical behavior, packaging, or cancellation races. |
| GitComet | Add an explicit deterministic UI runtime; test reducer effects below GPUI and typed input through a test window above it. [deterministic runtime](https://github.com/Auto-Explore/GitComet/blob/8edad8a4b16ae590c8ed0b18e74df5e1b493fdc4/crates/gitcomet-ui-gpui/src/ui_runtime.rs#L5-L101), [Ctrl+S GPUI test](https://github.com/Auto-Explore/GitComet/blob/8edad8a4b16ae590c8ed0b18e74df5e1b493fdc4/crates/gitcomet-ui-gpui/src/view/panels/tests/shortcuts.rs#L5849-L5886) | Its normal CI excludes UI Clippy and most UI tests; source volume must not be confused with enforced coverage. [CI exclusions](https://github.com/Auto-Explore/GitComet/blob/8edad8a4b16ae590c8ed0b18e74df5e1b493fdc4/.github/workflows/cross-platform-tests.yml#L104-L269) |
| OpenLogi | Use memory-only persistence, byte-level protocol golden tests, and watcher tests that retain the last good value across transient failure. [memory-only seam](https://github.com/AprilNEA/OpenLogi/blob/ae87aaa7ffb9f02b45445a6950faae8966cbca13/crates/openlogi-gui/src/state.rs#L286-L316), [wire tests](https://github.com/AprilNEA/OpenLogi/blob/ae87aaa7ffb9f02b45445a6950faae8966cbca13/crates/openlogi-agent-core/tests/wire_format.rs#L1-L80), [watcher recovery](https://github.com/AprilNEA/OpenLogi/blob/ae87aaa7ffb9f02b45445a6950faae8966cbca13/crates/openlogi-agent-core/src/watchers/inventory.rs#L342-L413) | Platform test jobs are asymmetric; Windows Clippy is not a Windows behavioral test. [CI matrix](https://github.com/AprilNEA/OpenLogi/blob/ae87aaa7ffb9f02b45445a6950faae8966cbca13/.github/workflows/ci.yml#L120-L198) |
| Codux | Test migrations, protocol chunking, bounded transports, and FFI constants at their stable boundaries. [desktop/protocol tests](https://github.com/duxweb/codux/blob/3f0856847b51700be8ce7fb8746d8c501aad10a8/apps/desktop/src/app/tests.rs#L63-L170), [transport/FFI tests](https://github.com/duxweb/codux/blob/3f0856847b51700be8ce7fb8746d8c501aad10a8/crates/codux-remote-transport/src/iroh_link.rs#L1790-L1897) | A local `test` recipe is not a PR gate; its PR workflow omits the main Rust and Flutter behavior suites. [recipe/workflow mismatch](https://github.com/duxweb/codux/blob/3f0856847b51700be8ce7fb8746d8c501aad10a8/.github/workflows/build-desktop-test.yml#L1-L92) |
| Pulsar-Native | Test dependency graphs as pure algorithms and native plugin contracts with purpose-built fixture libraries. [graph tests](https://github.com/Far-Beyond-Pulsar/Pulsar-Native/blob/5ab38b93012a7a02c1263afe7644f211224f8a44/crates/core/engine/src/init/graph.rs#L363-L479), [plugin fixture](https://github.com/Far-Beyond-Pulsar/Pulsar-Native/blob/5ab38b93012a7a02c1263afe7644f211224f8a44/crates/core/plugin_manager/tests/plugin_loading.rs#L1-L106) | Provider-switch unit tests do not prove task failure, timeout, cancellation, shutdown, or native close behavior. |
| onetcli | A queued fake HTTP client should both provide responses and capture requests so fallback policy is observable. [fake and fallback tests](https://github.com/feigeCode/onetcli/blob/e04b56ddc803e5c7fd5ec05718938edd3afb444d/main/src/update/mod.rs#L343-L617) | `include_str!` plus source substring assertions are refactor-fragile and are not behavior tests. [source-shape assertions](https://github.com/feigeCode/onetcli/blob/e04b56ddc803e5c7fd5ec05718938edd3afb444d/main/src/onetcli_app.rs#L1179-L1205) |
| Hummingbird | Use generated media and dummy devices to test allocation, bit correctness, EOF/backpressure, cancellation, channel close, and device recovery without physical hardware. [audio tests](https://github.com/hummingbird-player/hummingbird/blob/b07d12945f585774817386d24c5cf665d2c9558a/src/playback/tests/alloc_guard.rs#L12-L60), [scanner failure tests](https://github.com/hummingbird-player/hummingbird/blob/b07d12945f585774817386d24c5cf665d2c9558a/src/library/scan.rs#L1596-L1752) | Dummy devices cannot prove real driver timing, App quit joins, or platform callback behavior. |
| tty7 | Layer protocol tests, socket-pair tests, GPUI event-pump tests, and a few real-process scenarios; give integration jobs deadlines. [GPUI output chain](https://github.com/l0ng-ai/tty7/blob/72060d825797e806d231bbe5bd5f08e53ad0632a/src/terminal/view.rs#L10355-L10393), [process harness](https://github.com/l0ng-ai/tty7/blob/72060d825797e806d231bbe5bd5f08e53ad0632a/crates/tty7-server/tests/pane_send_input.rs#L9-L176) | Timeout only contains a hang; it does not prove the underlying suite is non-flaky or identify backlog ownership. [CI deadline](https://github.com/l0ng-ai/tty7/blob/72060d825797e806d231bbe5bd5f08e53ad0632a/.github/workflows/ci.yml#L95-L164) |
| Termy | Directly test wake coalescing, damage tracking, cache equivalence, quit policy, and platform PTY lifecycle. [wake/damage/quit tests](https://github.com/lassejlv/termy/blob/4144d1d07692ebf14198a9baf64238819b32639c/crates/core/src/runtime.rs#L3622-L3962), [Windows PTY tests](https://github.com/lassejlv/termy/blob/4144d1d07692ebf14198a9baf64238819b32639c/crates/temon/src/pty_windows_tests.rs#L593-L648) | Platform-native tests complement rather than replace headless UI and pure-core tests. |
| PicoForge | Keep binary protocol, parser, and mapping logic testable without GPUI. [HAL and UI mapping tests](https://github.com/librekeys/picoforge/blob/868435c0f422e6472cde5baf0f8cf52a9635bc72/src/hal/common/led.rs#L44-L114) | Direct hardware access without a transport seam leaves hot-plug, permission, partial-write, cancellation, and UI error paths untestable without hardware. |
| Monocurl | Drive a real domain pipeline below UI and test version guards and coalescing independently. [lex-to-execute harness](https://github.com/monocurl/monocurl/blob/d6c74da087114f6d7db2c8374b070ad78692db34/crates/integration_tests/tests/basic_executor_tests.rs#L1-L27), [version/coalescing tests](https://github.com/monocurl/monocurl/blob/d6c74da087114f6d7db2c8374b070ad78692db34/crates/monocurl/src/state/textual_state.rs#L1263-L1400) | Deep domain tests still do not prove the complete window input-to-preview-to-export path. |
| nohrs | Use `TestAppContext` for background preview, subscriptions, and session round trips. [GPUI tests](https://github.com/noh-rs/nohrs/blob/a06ed708ffd3422186198ce349fda7894eb1d075/crates/nohrs-pages/src/explorer/tests.rs#L168-L200) | Coverage exclusions can hide view/window/glue roots, and a separate unused component test does not prove the component actually rendered by the app. [coverage configuration](https://github.com/noh-rs/nohrs/blob/a06ed708ffd3422186198ce349fda7894eb1d075/.github/workflows/ci.yml#L220-L353) |
| zqlz | Test connection/error classification, request normalization, and real-driver cases separately. [heartbeat/request tests](https://github.com/samurmaykrr/zqlz/blob/d8364b927e100ab124dc935536a398f45da24089/crates/zqlz-connection/src/manager.rs#L900-L1009) | Thousands of test annotations do not cover the known stale-completion/result-limit races, and its release workflow runs no workspace test gate. [release workflow](https://github.com/samurmaykrr/zqlz/blob/d8364b927e100ab124dc935536a398f45da24089/.github/workflows/release.yml#L1-L120) |
| Ropy | Test bounded-channel semantics, newest-wins replacement, failure cleanup, and storage rules against an in-memory backend. [channel/listener tests](https://github.com/StudentWeis/ropy/blob/1264415bf7d8746d5333f7a0405fecd15f466084/src/app.rs#L355-L439), [memory/repository tests](https://github.com/StudentWeis/ropy/blob/1264415bf7d8746d5333f7a0405fecd15f466084/src/repository/tests/dedup_tests.rs#L32-L110) | Memory backends do not prove real clipboard watchers, focus, OS paste, or exit races. |
| Zedis | Use `#[gpui::test]` for application selection, route, and activation state; keep parser, credential, and error tests below GPUI. [GPUI state tests](https://github.com/vicanso/zedis/blob/f434f780522c2f9ff2dc0853db2222abb2232908/src/states/app.rs#L1614-L1758) | A soft-fail Linux smoke is evidence of an attempted check, not a hard gate. [first-frame workflow](https://github.com/vicanso/zedis/blob/f434f780522c2f9ff2dc0853db2222abb2232908/.github/workflows/smoke.yml#L1-L113) |
| Vleer | A local TCP fixture can test updater parsing, signatures, and failure cleanup. [updater tests](https://github.com/vleerapp/vleer/blob/af3a5ae0b960178629a49053bd35bd4ad6cb2406/tests/updater.rs#L89-L266) | Concentrated updater tests leave playback, queue, GPUI Entity/render, scanner, and window exit unproved; a benchmark-shaped `#[test]` is not performance evidence. [benchmark/test inventory](https://github.com/vleerapp/vleer/blob/af3a5ae0b960178629a49053bd35bd4ad6cb2406/tests/db_bench.rs#L16-L85) |

## Layer 1: pure core tests

Pure state-transition tests are the default for business policy because they
are fast, deterministic, and do not need a display, GPUI context, network,
filesystem, database, or device.

A behavior belongs here when its contract can be expressed as input plus prior
state producing state, typed outcome, or effect. The minimum matrix is:

- initial state and normal success;
- invalid command and typed failure;
- idempotence or repeated intent;
- request generation/revision ordering;
- reset/cancel followed by a late completion;
- boundary values and migration/golden compatibility when applicable.

OpenLogi’s byte-level protocol tests show when a golden is appropriate: the
bytes are the cross-version contract, rather than an incidental rendering.
[Fixed-byte protocol source](https://github.com/AprilNEA/OpenLogi/blob/ae87aaa7ffb9f02b45445a6950faae8966cbca13/crates/openlogi-agent-core/tests/wire_format.rs#L1-L80)

## Layer 2: fake adapters

Add a fake only at a real variation point. The fake should expose observable
requests and controllable outcomes, not reproduce the production
implementation. A useful fake supports, as applicable:

- immediate success and typed failure;
- delayed or manually released completion;
- never-completing work;
- ordered and out-of-order responses;
- cancellation before and after the side effect;
- partial artifact creation and cleanup failure;
- channel full/disconnect;
- a controllable clock or executor instead of wall-clock sleep.

Zed’s filesystem/HTTP/clock/install overrides, onetcli’s response queue and
request capture, OpenLogi’s memory-only persistence, and Ropy’s in-memory
storage demonstrate the common shape. [Zed updater seam](https://github.com/zed-industries/zed/blob/c6b01d8a203a6dc8c06a89e05ee4dec69de55cf0/crates/auto_update/src/auto_update.rs#L1362-L1468), [onetcli fake](https://github.com/feigeCode/onetcli/blob/e04b56ddc803e5c7fd5ec05718938edd3afb444d/main/src/update/mod.rs#L343-L423), [OpenLogi persistence](https://github.com/AprilNEA/OpenLogi/blob/ae87aaa7ffb9f02b45445a6950faae8966cbca13/crates/openlogi-gui/src/state.rs#L286-L316), [Ropy repository tests](https://github.com/StudentWeis/ropy/blob/1264415bf7d8746d5333f7a0405fecd15f466084/src/repository/tests/dedup_tests.rs#L32-L110)

Do not introduce a universal service locator or mock every function. Keep one
production adapter and one deterministic test adapter behind a narrow
behavioral interface when failure timing or implementation variation is real.

## Layer 3: headless GPUI tests

GPUI 0.2.2 already supplies the required primitives:

- feature `test-support` enables leak detection plus collection, utility, HTTP,
  Wayland, and X11 test support (`gpui-0.2.2/Cargo.toml`, lines 56–64);
- `#[gpui::test]` creates context-aware tests whose output is compatible with
  `cargo test` and `cargo-nextest` (`gpui-0.2.2/src/test.rs`, lines 1–27);
- `TestAppContext` contains deterministic foreground/background executors and a
  test platform (`gpui-0.2.2/src/app/test_context.rs`, lines 15–31 and 122–149);
- `add_window` and `add_window_view` create a test-backed window and root Entity
  (`gpui-0.2.2/src/app/test_context.rs`, lines 213–280);
- `dispatch_action`, `simulate_keystrokes`, and `simulate_input` drive the
  focused interaction path and drain ready work (`gpui-0.2.2/src/app/test_context.rs`,
  lines 396–449);
- `VisualTestContext` provides window-scoped updates, typed Action/input, mouse
  events, resize, debug bounds, draw, and close simulation
  (`gpui-0.2.2/src/app/test_context.rs`, lines 665–837 and 839–881);
- notification and typed-event streams can observe Entity behavior without
  source-string assertions (`gpui-0.2.2/src/app/test_context.rs`, lines 466–531).

For this template, the reusable harness should initialize the same globals and
`gpui-component` state as production, open `TemplateView`, return its Entity and
`VisualTestContext`, and provide one explicit “drain ready work” helper.

The first minimum GPUI suite should prove:

1. each typed Action reaches the one production handler;
2. the Entity/Snapshot changes as expected;
3. keyboard and pointer forms of one intent converge on that handler when both
   are product contracts;
4. background completion commits only on the GPUI foreground context;
5. the latest request wins and reset/cancel rejects an older completion;
6. render/draw does not create duplicate work;
7. focus and visible error/recovery state are observable where applicable;
8. closing the window or releasing the Entity prevents a late UI commit.

Prefer typed Action dispatch to coordinate-based mouse clicks for semantic
behavior. Use mouse simulation only when hit-testing/pointer behavior is itself
the contract. GitComet demonstrates input-to-state testing; gpui-component
demonstrates direct component Entity testing. [GitComet shortcut test](https://github.com/Auto-Explore/GitComet/blob/8edad8a4b16ae590c8ed0b18e74df5e1b493fdc4/crates/gitcomet-ui-gpui/src/view/panels/tests/shortcuts.rs#L5849-L5886), [gpui-component Select tests](https://github.com/longbridge/gpui-component/blob/26cc9366abb27ccedce386ac99a615a8fa7018da/crates/ui/src/select.rs#L802-L894)

## Layer 4: deterministic async and lifecycle

The GPUI test executor is designed for deterministic foreground/background
work. `run_until_parked` executes ready tasks and panics when outstanding work
remains unless parking was explicitly allowed; `tick`, `advance_clock`, and
`simulate_random_delay` offer narrower scheduling control
(`gpui-0.2.2/src/executor.rs`, lines 381–423).

This should be used to test protocols, not implementation timing:

| Contract | Required scenario |
|---|---|
| Request identity | Start A, start B, complete A, then B; only B commits. |
| Cancellation | Request cancel, hold completion, release it; state remains cancelled and partial artifacts are cleaned. |
| Owner lifetime | Drop view/window before completion; no Entity update, leak, panic, or orphan task remains. |
| Channel capacity | Fill the bounded channel; assert block/drop/coalesce/retry policy and surfaced send failure. |
| Disconnect | Drop producer and consumer independently; each task reaches a terminal state. |
| Notifications | Semantically equal updates do not produce unconditional refresh loops. |
| Shutdown | close, Quit, and last-window paths converge; finite work drains or reaches its declared deadline. |

Termy directly tests wake coalescing, damage, and close policy; Ropy tests
capacity and newest-wins; tty7 layers socket, GPUI, and process tests. These are
more reusable than sleeping and hoping a race occurs. [Termy runtime tests](https://github.com/lassejlv/termy/blob/4144d1d07692ebf14198a9baf64238819b32639c/crates/core/src/runtime.rs#L3622-L3962), [Ropy capacity tests](https://github.com/StudentWeis/ropy/blob/1264415bf7d8746d5333f7a0405fecd15f466084/src/app.rs#L355-L439), [tty7 relink tests](https://github.com/l0ng-ai/tty7/blob/72060d825797e806d231bbe5bd5f08e53ad0632a/src/terminal/remote.rs#L2215-L2295)

Wall-clock sleeps in behavior tests should be rejected. Zed mechanically bans
non-deterministic timer use in the relevant codebase. [Disallowed methods](https://github.com/zed-industries/zed/blob/c6b01d8a203a6dc8c06a89e05ee4dec69de55cf0/clippy.toml#L8-L18)

## Layer 5: native Windows smoke

Headless GPUI tests use a test platform. They do not prove Win32 window
creation, graphics initialization, fonts, native event delivery, packaging,
signing, or shutdown of the real desktop process.

The minimum Windows smoke should launch a dedicated test mode and prove, with a
deadline and reliable exit code:

1. process starts;
2. `gpui-component` and application globals initialize;
3. a main window reaches first frame;
4. one typed Action changes visible state;
5. close requests the production shutdown path;
6. the process exits within the deadline without a crash.

Keep this suite deliberately small. Zedis demonstrates a concrete first-frame
workflow but also shows why soft-fail smoke is not a gate. [Zedis smoke workflow](https://github.com/vicanso/zedis/blob/f434f780522c2f9ff2dc0853db2222abb2232908/.github/workflows/smoke.yml#L1-L113) Termy demonstrates that Windows-native resource behavior deserves a separate
platform test. [Termy ConPTY test](https://github.com/lassejlv/termy/blob/4144d1d07692ebf14198a9baf64238819b32639c/crates/temon/src/pty_windows_tests.rs#L593-L648)

The 18-project evidence does not establish a single, universally reliable
Windows GPUI first-frame harness. The template must treat this as a new
platform contract, validate it on its own Windows runner, and report it
separately from `cargo build` and headless tests.

## Layer 6: CI and evidence

The canonical PR gate should contain separate, visible steps for:

- formatting;
- Clippy with warnings denied;
- pure core and fake-adapter tests;
- GPUI headless tests with `test-support` enabled;
- repository/architecture contracts;
- explicit Windows target build;
- Windows native smoke when the runner supports desktop interaction;
- packaging, performance, accessibility, and visual review only when those
  gates actually exist.

Do not silently exclude `app-ui`. GitComet is the clearest counterexample:
large GPUI test source coexists with CI paths that skip UI Clippy and most UI
tests. [Quality workflow](https://github.com/Auto-Explore/GitComet/blob/8edad8a4b16ae590c8ed0b18e74df5e1b493fdc4/.github/workflows/rust.yml#L17-L173), [cross-platform exclusions](https://github.com/Auto-Explore/GitComet/blob/8edad8a4b16ae590c8ed0b18e74df5e1b493fdc4/.github/workflows/cross-platform-tests.yml#L104-L269)

Do not confuse packaging/build with tests. Codux’s PR workflow builds/packages
without running its main behavior suites; zqlz’s release workflow packages
without a workspace test gate. [Codux PR workflow](https://github.com/duxweb/codux/blob/3f0856847b51700be8ce7fb8746d8c501aad10a8/.github/workflows/build-desktop-test.yml#L1-L92), [zqlz release workflow](https://github.com/samurmaykrr/zqlz/blob/d8364b927e100ab124dc935536a398f45da24089/.github/workflows/release.yml#L1-L120)

Every delivery should record `pass`, `fail`, or `not run` for each layer. A
workflow declaration is only configuration evidence; current run output is the
pass evidence.

## Agent-facing test contract to implement

An Agent changing behavior should be required to:

1. map the changed command/action, authoritative owner, effect, background and
   foreground boundaries, stale guard, notification/render, failure, and
   close/quit path;
2. choose the lowest applicable test layer and explain why higher layers are or
   are not needed;
3. add or update tests in the same change, unless the change is demonstrably
   non-behavioral;
4. cover success and each applicable failure/cancel/stale/disconnect/close row;
5. avoid wall-clock sleep, real network, user files, credentials, and physical
   devices in default tests;
6. test stable behavior and typed interfaces, not source layout or log text;
7. run focused tests first, then the canonical full gate;
8. report excluded and unrun layers without promoting them to passes.

A feature is incomplete when a new observable branch has no behavior test and
no recorded explanation of why it cannot be automated at the applicable
layer. A passing pure reducer test cannot prove an Action is wired to the
window; a passing headless GPUI test cannot prove a native Windows first frame;
a first-frame smoke cannot prove failure recovery, lifecycle convergence, or
visual correctness.

## Recommended minimum template artifacts

The research supports adding these reusable artifacts to the template:

- a normative `docs/testing-standard.md` containing the Agent contract and
  acceptance matrix;
- `app-ui` dev dependency on the exact workspace GPUI version with
  `features = ["test-support"]`;
- a small `app-ui` test harness that initializes production globals and returns
  the root Entity plus `VisualTestContext`;
- typed Actions for user intents so tests do not depend on screen coordinates;
- representative `#[gpui::test]` cases for action, async completion,
  stale-result rejection, render idempotence, and close/drop;
- fake-adapter examples added only with the first real external boundary;
- a focused GPUI test command plus inclusion in the canonical full gate;
- a bounded Windows first-frame smoke with a distinct evidence result;
- CI checks preventing `app-ui`/GPUI tests from being silently skipped.

This is the smallest scaffold that materially increases an Agent’s ability to
check Rust + GPUI work without importing Zed’s scale or relying on fragile
visual automation.
