use super::native_bridge::testing::Backend;
use super::*;
use gpui_kit::{Context, Render, TestAppContext, Window, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::atomic::Ordering,
    time::Duration,
};

struct Content {
    count: usize,
}

#[gpui_kit::test]
fn owner_close_hides_without_advancing_a_poll_timer(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let overlay = open(cx, owner, host);
    cx.run_until_parked();
    assert!(!backend.hidden.load(Ordering::SeqCst));
    assert!(
        owner
            .update(cx, |_, window, _| window.remove_window())
            .is_ok()
    );
    cx.run_until_parked();
    assert!(backend.hidden.load(Ordering::SeqCst));
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.phase)
            .ok(),
        Some(OverlayPhase::Closed)
    );
}

#[gpui_kit::test]
fn suspension_releases_gpui_pointer_capture(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let overlay = open(cx, owner, host);
    cx.run_until_parked();
    for hidden in [false, true] {
        assert!(
            cx.update(|cx| overlay.update(cx, |_, window, _| window
                .capture_pointer(gpui_kit::HitboxId::placeholder())))
                .is_ok()
        );
        if hidden {
            let mut sample = backend.sample(host, 2);
            sample.visibility_reason = Some(HiddenReason::Background);
            backend.submit(sample);
        } else {
            assert!(
                cx.update(|cx| overlay.set_input_mode(InputMode::Passthrough, cx))
                    .is_ok()
            );
        }
        cx.run_until_parked();
        assert_eq!(
            cx.update(|cx| overlay.update(cx, |_, window, _| window.captured_hitbox()))
                .ok(),
            Some(None)
        );
    }
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    cx.run_until_parked();
}

#[gpui_kit::test]
fn native_setup_failures_release_content_without_ready(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    for flag in [&backend.fail_bind, &backend.fail_start, &backend.fail_mode] {
        flag.store(true, Ordering::SeqCst);
        let overlay = open(cx, owner, host);
        let content = cx
            .update(|cx| overlay.content(cx))
            .unwrap_or_else(|error| panic!("{error}"))
            .downgrade();
        let events = Rc::new(RefCell::new(Vec::new()));
        let output = events.clone();
        let _subscription = cx
            .update(|cx| overlay.observe(cx, move |event, _| output.borrow_mut().push(event.kind)));
        tick(cx);
        let state = cx
            .update(|cx| overlay.snapshot(cx))
            .unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(state.phase, OverlayPhase::Closed);
        assert!(state.error.is_some());
        assert!(content.upgrade().is_none());
        assert!(!events.borrow().contains(&OverlayEventKind::Ready));
        assert_eq!(
            events
                .borrow()
                .iter()
                .filter(|kind| **kind == OverlayEventKind::Closed)
                .count(),
            1
        );
    }
}

#[gpui_kit::test]
fn cleanup_failure_is_retained_in_terminal_diagnostics(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    backend.fail_finish.store(true, Ordering::SeqCst);
    cx.update(|cx| overlay.close(cx))
        .unwrap_or_else(|error| panic!("{error}"));
    tick(cx);
    let state = cx
        .update(|cx| overlay.snapshot(cx))
        .unwrap_or_else(|error| panic!("{error}"));
    assert_eq!(state.phase, OverlayPhase::Closed);
    assert_eq!(
        state.error.map(|error| error.kind),
        Some(ErrorKind::TrackingFailed)
    );
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
}

#[gpui_kit::test]
fn hide_show_and_mode_changes_keep_the_original_business_entity(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let factories = Rc::new(Cell::new(0));
    let calls = factories.clone();
    let overlay = cx
        .update(|cx| {
            open_window(
                host,
                OverlayOptions {
                    margins: Default::default(),
                    owner: owner.into(),
                    input_mode: InputMode::Interactive,
                },
                move |_, cx| {
                    calls.set(calls.get() + 1);
                    cx.new(|_| Content { count: 7 })
                },
                cx,
            )
        })
        .unwrap_or_else(|error| panic!("{error}"));
    tick(cx);
    let identity = cx
        .update(|cx| overlay.content(cx))
        .unwrap_or_else(|error| panic!("{error}"))
        .entity_id();
    cx.update(|cx| {
        overlay.update(cx, |content, _, cx| {
            content.count = 19;
            cx.notify();
        })
    })
    .unwrap_or_else(|error| panic!("{error}"));
    for (sequence, reason) in [
        (2, Some(HiddenReason::Minimized)),
        (3, Some(HiddenReason::Background)),
        (4, None),
    ] {
        let mut sample = backend.sample(host, sequence);
        sample.visibility_reason = reason;
        backend.submit(sample);
        tick(cx);
        assert_eq!(
            cx.update(|cx| overlay.snapshot(cx))
                .unwrap_or_else(|error| panic!("{error}"))
                .hidden_reason,
            reason
        );
    }
    for mode in [InputMode::Passthrough, InputMode::Interactive] {
        cx.update(|cx| overlay.set_input_mode(mode, cx))
            .unwrap_or_else(|error| panic!("{error}"));
        tick(cx);
        assert_eq!(
            cx.update(|cx| overlay.content(cx))
                .unwrap_or_else(|error| panic!("{error}"))
                .entity_id(),
            identity
        );
        assert_eq!(
            cx.update(|cx| overlay.update(cx, |content, _, _| content.count))
                .unwrap_or_else(|error| panic!("{error}")),
            19
        );
    }
    assert_eq!(factories.get(), 1);
    cx.update(|cx| overlay.close(cx))
        .unwrap_or_else(|error| panic!("{error}"));
    tick(cx);
}

#[gpui_kit::test]
fn host_terminal_closes_once_and_late_snapshot_cannot_reopen(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    let mut terminal = backend.sample(host, 2);
    terminal.terminal = Some(native_bridge::failure(
        ErrorKind::HostGone,
        "Host destroyed",
    ));
    backend.submit(terminal);
    tick(cx);
    let closed = cx
        .update(|cx| overlay.snapshot(cx))
        .unwrap_or_else(|error| panic!("{error}"));
    assert_eq!(closed.phase, OverlayPhase::Closed);
    assert_eq!(
        closed.error.as_ref().map(|error| error.kind),
        Some(ErrorKind::HostGone)
    );
    backend.submit(backend.sample(host, 3));
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .unwrap_or_else(|error| panic!("{error}")),
        closed
    );
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
}
impl Render for Content {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        gpui_kit::div().child(self.count.to_string())
    }
}
fn setup(cx: &mut TestAppContext) -> (gpui_kit::WindowHandle<Content>, HostWindowId, Backend) {
    crate::test_support::init_test_app(cx);
    let backend = Backend::default();
    cx.set_global(backend.clone());
    let owner = cx.add_window(|_, _| Content { count: 0 });
    (owner, HostWindowId::fixture(42), backend)
}
fn tick(cx: &mut TestAppContext) {
    cx.run_until_parked();
    cx.background_executor
        .advance_clock(Duration::from_millis(32));
    cx.run_until_parked();
}
fn open(
    cx: &mut TestAppContext,
    owner: gpui_kit::WindowHandle<Content>,
    host: HostWindowId,
) -> OverlayWindow<Content> {
    cx.update(|cx| {
        open_window(
            host,
            OverlayOptions {
                margins: Default::default(),
                owner: owner.into(),
                input_mode: InputMode::Interactive,
            },
            |_, cx| cx.new(|_| Content { count: 7 }),
            cx,
        )
    })
    .unwrap_or_else(|error| panic!("{error}"))
}

#[gpui_kit::test]
fn handle_drop_keeps_content_until_owner_closes(cx: &mut TestAppContext) {
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    let content = cx.update(|cx| {
        overlay
            .content(cx)
            .unwrap_or_else(|error| panic!("{error}"))
    });
    let weak = content.downgrade();
    drop(content);
    drop(overlay);
    tick(cx);
    assert!(weak.upgrade().is_some());
    assert!(
        owner
            .update(cx, |_, window, _| window.remove_window())
            .is_ok()
    );
    tick(cx);
    assert!(weak.upgrade().is_none());
}

#[gpui_kit::test]
fn closing_releases_content_and_late_subscriber_sees_one_closed(cx: &mut TestAppContext) {
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
    let events = Rc::new(RefCell::new(Vec::new()));
    let output = events.clone();
    let _subscription =
        cx.update(|cx| overlay.observe(cx, move |event, _| output.borrow_mut().push(event.kind)));
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
    assert_eq!(*events.borrow(), vec![OverlayEventKind::Closed]);
    assert!(cx.update(|cx| overlay.content(cx)).is_err());
    assert!(cx.update(|cx| overlay.update(cx, |_, _, _| ())).is_err());
}

#[gpui_kit::test]
fn mode_failure_preserves_applied_mode_and_content(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    backend.fail_mode.store(true, Ordering::SeqCst);
    assert!(
        cx.update(|cx| overlay.set_input_mode(InputMode::Passthrough, cx))
            .is_ok()
    );
    tick(cx);
    let state = cx.update(|cx| {
        overlay
            .snapshot(cx)
            .unwrap_or_else(|error| panic!("{error}"))
    });
    assert_eq!(state.input_mode, InputMode::Interactive);
    assert_eq!(
        state.error.map(|error| error.kind),
        Some(ErrorKind::NativeSetupFailed)
    );
    assert_eq!(
        cx.update(|cx| overlay.update(cx, |view, _, _| view.count))
            .ok(),
        Some(7)
    );
    assert!(
        cx.update(|cx| overlay.set_input_mode(InputMode::Passthrough, cx))
            .is_ok()
    );
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.input_mode)
            .ok(),
        Some(InputMode::Passthrough)
    );
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
}

#[gpui_kit::test]
fn old_generation_terminal_cannot_close_current_session(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    let mut stale = backend.sample(HostWindowId::fixture(41), 900);
    stale.terminal = Some(native_bridge::failure(
        ErrorKind::HostGone,
        "old generation",
    ));
    backend.submit(stale);
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.phase)
            .ok(),
        Some(OverlayPhase::Attached)
    );
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
}

#[gpui_kit::test]
fn quit_completion_waits_for_overlay_close(cx: &mut TestAppContext) {
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    let finished = Rc::new(Cell::new(false));
    let output = finished.clone();
    cx.update(|cx| prepare_quit(cx, move |_| output.set(true)));
    assert!(!finished.get());
    tick(cx);
    assert!(finished.get());
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.phase)
            .ok(),
        Some(OverlayPhase::Closed)
    );
}

#[gpui_kit::test]
fn business_remove_window_uses_the_same_terminal_path(cx: &mut TestAppContext) {
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    assert!(
        cx.update(|cx| overlay.update(cx, |_, window, _| window.remove_window()))
            .is_ok()
    );
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.phase)
            .ok(),
        Some(OverlayPhase::Closed)
    );
    assert!(cx.update(|cx| overlay.content(cx)).is_err());
}

#[gpui_kit::test]
fn close_during_attach_never_publishes_ready(cx: &mut TestAppContext) {
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    let events = Rc::new(RefCell::new(Vec::new()));
    let output = events.clone();
    let _subscription =
        cx.update(|cx| overlay.observe(cx, move |event, _| output.borrow_mut().push(event.kind)));
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
    assert!(!events.borrow().contains(&OverlayEventKind::Ready));
    assert_eq!(
        events
            .borrow()
            .iter()
            .filter(|event| **event == OverlayEventKind::Closed)
            .count(),
        1
    );
}

#[gpui_kit::test]
fn duplicate_attach_and_overlay_owner_are_rejected(cx: &mut TestAppContext) {
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    let duplicate = cx.update(|cx| {
        open_window(
            host,
            OverlayOptions {
                margins: Default::default(),
                owner: owner.into(),
                input_mode: InputMode::Interactive,
            },
            |_, cx| cx.new(|_| Content { count: 0 }),
            cx,
        )
    });
    assert_eq!(
        duplicate.err().map(|error| error.kind),
        Some(ErrorKind::AlreadyAttached)
    );
    tick(cx);
    let child_owner = cx
        .update(|cx| overlay.update(cx, |_, window, _| window.window_handle()))
        .unwrap_or_else(|error| panic!("{error}"));
    let child = cx.update(|cx| {
        open_window(
            HostWindowId::fixture(43),
            OverlayOptions {
                margins: Default::default(),
                owner: child_owner,
                input_mode: InputMode::Interactive,
            },
            |_, cx| cx.new(|_| Content { count: 0 }),
            cx,
        )
    });
    assert_eq!(
        child.err().map(|error| error.kind),
        Some(ErrorKind::WindowCreateFailed)
    );
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
}

#[gpui_kit::test]
fn bubbled_cancel_leaves_interactive_mode(cx: &mut TestAppContext) {
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    assert!(
        cx.update(|cx| overlay.update(cx, |_, window, cx| window
            .dispatch_action(Box::new(gpui_kit::component::dialog::Cancel), cx)))
            .is_ok()
    );
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.input_mode)
            .ok(),
        Some(InputMode::Passthrough)
    );
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
}

#[gpui_kit::test]
fn dialog_consumes_cancel_before_overlay_fallback(cx: &mut TestAppContext) {
    use gpui_kit::component::WindowExt as _;
    let (owner, host, _) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    assert!(
        cx.update(|cx| overlay.update(cx, |_, window, cx| window
            .open_dialog(cx, |dialog, _, _| dialog.title("Dialog"))))
            .is_ok()
    );
    tick(cx);
    assert!(
        cx.update(|cx| overlay.update(cx, |_, window, cx| window
            .dispatch_action(Box::new(gpui_kit::component::dialog::Cancel), cx)))
            .is_ok()
    );
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.input_mode)
            .ok(),
        Some(InputMode::Interactive)
    );
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
}

#[gpui_kit::test]
fn composition_cancel_does_not_also_leave_interactive_mode(cx: &mut TestAppContext) {
    use gpui_kit::component::input::{Input, InputState};
    use gpui_kit::{EntityInputHandler as _, Focusable as _};
    struct InputContent(gpui_kit::Entity<InputState>);
    impl Render for InputContent {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            Input::new(&self.0)
        }
    }
    let (owner, host, _) = setup(cx);
    let overlay = cx
        .update(|cx| {
            open_window(
                host,
                OverlayOptions {
                    margins: Default::default(),
                    owner: owner.into(),
                    input_mode: InputMode::Interactive,
                },
                |window, cx| {
                    let input = cx.new(|cx| InputState::new(window, cx));
                    let focus = input.focus_handle(cx);
                    window.focus(&focus, cx);
                    cx.new(|_| InputContent(input))
                },
                cx,
            )
        })
        .unwrap_or_else(|error| panic!("{error}"));
    tick(cx);
    assert!(
        cx.update(|cx| overlay.update(cx, |content, window, cx| {
            content.0.update(cx, |input, cx| {
                input.replace_and_mark_text_in_range(None, "中", None, window, cx)
            });
        }))
        .is_ok()
    );
    tick(cx);
    assert!(
        cx.update(|cx| overlay.update(cx, |_, window, cx| window
            .dispatch_action(Box::new(gpui_kit::component::input::Escape), cx)))
            .is_ok()
    );
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.input_mode)
            .ok(),
        Some(InputMode::Interactive)
    );
    assert!(
        cx.update(|cx| overlay.update(cx, |_, window, cx| window
            .dispatch_action(Box::new(gpui_kit::component::input::Escape), cx)))
            .is_ok()
    );
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .map(|state| state.input_mode)
            .ok(),
        Some(InputMode::Passthrough)
    );
    assert!(cx.update(|cx| overlay.close(cx)).is_ok());
    tick(cx);
}

#[gpui_kit::test]
fn margins_apply_without_host_events_preserve_content_and_recover_empty(cx: &mut TestAppContext) {
    let (owner, host, backend) = setup(cx);
    let overlay = open(cx, owner, host);
    tick(cx);
    let identity = cx
        .update(|cx| overlay.content(cx))
        .unwrap_or_else(|e| panic!("{e}"))
        .entity_id();
    let margins = OverlayMargins {
        top: 40,
        right: 8,
        bottom: 6,
        left: 4,
    };
    for desired in [
        margins,
        OverlayMargins {
            top: u32::MAX,
            ..margins
        },
        OverlayMargins::default(),
    ] {
        cx.update(|cx| overlay.set_margins(desired, cx))
            .unwrap_or_else(|e| panic!("{e}"));
        cx.run_until_parked(); // no host event or polling clock needed
        let state = cx
            .update(|cx| overlay.snapshot(cx))
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(state.margins, desired);
        let raw = backend.sample(host, 1).physical_client_rect;
        assert_eq!(state.physical_client_rect, Some(raw));
        assert_eq!(state.physical_overlay_rect, Some(desired.inset(raw, 144)));
        assert_eq!(
            state.hidden_reason,
            if desired.top == u32::MAX {
                Some(HiddenReason::EmptyViewport)
            } else {
                None
            }
        );
        assert_eq!(
            cx.update(|cx| overlay.content(cx))
                .unwrap_or_else(|e| panic!("{e}"))
                .entity_id(),
            identity
        );
    }
    cx.update(|cx| overlay.set_margins(margins, cx))
        .unwrap_or_else(|e| panic!("{e}"));
    let mut sample = backend.sample(host, 2);
    sample.dpi = 192;
    backend.submit(sample.clone());
    tick(cx);
    assert_eq!(
        cx.update(|cx| overlay.snapshot(cx))
            .unwrap_or_else(|e| panic!("{e}"))
            .physical_overlay_rect,
        Some(margins.inset(sample.physical_client_rect, 192))
    );
    cx.update(|cx| overlay.close(cx))
        .unwrap_or_else(|e| panic!("{e}"));
    cx.run_until_parked();
    assert_eq!(
        cx.update(|cx| overlay.set_margins(margins, cx))
            .err()
            .map(|e| e.kind),
        Some(ErrorKind::SessionClosed)
    );
}
