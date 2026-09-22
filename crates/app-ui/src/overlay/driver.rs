use super::{
    native_bridge::{self, Watch},
    runtime,
    session::Session,
    types::*,
};
use gpui_kit::{App, AppContext as _, Entity};
use std::time::Duration;

/// The foreground driver owns the native binding. Native calls are deliberately
/// outside cx.update / Window updates: native resize callbacks synchronously reenter GPUI.
pub(super) fn start(session: &Entity<Session>, cx: &mut App) {
    let state = session.read(cx);
    let Some(window) = state.window else {
        return;
    };
    let host = state.snapshot.host;
    let id = state.snapshot.session_id;
    let changed = state.changed.clone();
    let weak = session.downgrade();
    let bound = window.update(cx, |_, window, cx| native_bridge::bind(window, cx));
    let task = cx.spawn(async move |cx| {
        let mut failure = None;
        let mut binding = match bound {
            Ok(Ok(binding)) => Some(binding),
            Ok(Err(error)) => {
                failure = Some(error);
                None
            }
            Err(error) => {
                failure = Some(native_bridge::failure(
                    native_bridge::ErrorKind::WindowCreateFailed,
                    &error.to_string(),
                ));
                None
            }
        };
        if let Some(binding) = binding.as_ref() {
            binding.set_change_signal(changed.clone());
        }
        let mut watch =
            if let Some(factory) = binding.as_ref().map(|binding| binding.watch_factory()) {
                let native_changed = changed.clone();
                match cx
                    .background_spawn(async move { factory.start(host, native_changed) })
                    .await
                {
                    Ok(watch) => Some(watch),
                    Err(error) => {
                        failure = Some(error);
                        None
                    }
                }
            } else {
                None
            };
        let mut applied_revision = None;
        let mut sequence = 0;
        let mut applied_margins = None;
        let mut saved_focus = None;
        let mut available = false;
        while failure.is_none() {
            let request = weak.update(cx, |session, cx| {
                let owner_alive = cx.windows().contains(&session.owner);
                if !owner_alive || !cx.windows().contains(&window) {
                    session.request_close(cx);
                }
                (
                    session.snapshot.phase.clone(),
                    session.desired_mode,
                    session.mode_revision,
                    session.desired_margins,
                )
            });
            let Ok((phase, mode, revision, margins)) = request else {
                break;
            };
            if !runtime::is_open(&phase) {
                break;
            }
            let Some(native) = binding.as_mut() else {
                break;
            };
            if applied_revision != Some(revision) {
                // Use AnyWindowHandle; borrowing Root itself would reenter Root
                // when WindowExt clears its dialogs.
                if applied_revision.is_some() {
                    let focus = window
                        .update(cx, |_, window, cx| super::root::suspend(window, cx))
                        .ok()
                        .flatten();
                    if focus.is_some() {
                        saved_focus = focus;
                    }
                }
                match native.set_mode(mode) {
                    Ok(()) => {
                        let focus_warning = if mode == native_bridge::InputMode::Passthrough {
                            native.return_focus(host).err()
                        } else {
                            None
                        };
                        if mode == native_bridge::InputMode::Interactive
                            && let Some(focus) = saved_focus.take()
                        {
                            let _ = window.update(cx, |_, window, cx| window.focus(&focus, cx));
                        }
                        let _ = weak.update(cx, |session, cx| {
                            if session.mode_revision == revision
                                && runtime::is_open(&session.snapshot.phase)
                            {
                                let changed = session.snapshot.input_mode != mode;
                                session.snapshot.input_mode = mode;
                                session.snapshot.error = None;
                                if changed {
                                    session.publish(OverlayEventKind::ModeChanged, cx);
                                }
                                if let Some(warning) = focus_warning {
                                    session.snapshot.error = Some(warning);
                                    session.publish(OverlayEventKind::OperationFailed, cx);
                                }
                            }
                        });
                    }
                    Err(error) if phase == OverlayPhase::Attaching || !native.usable() => {
                        failure = Some(error);
                        break;
                    }
                    Err(error) => {
                        if let Some(focus) = saved_focus.take() {
                            let _ = window.update(cx, |_, window, cx| window.focus(&focus, cx));
                        }
                        let _ = weak.update(cx, |session, cx| {
                            if session.mode_revision == revision
                                && runtime::is_open(&session.snapshot.phase)
                            {
                                session.desired_mode = session.snapshot.input_mode;
                                session.snapshot.error = Some(error);
                                session.publish(OverlayEventKind::OperationFailed, cx);
                            }
                        });
                    }
                }
                applied_revision = Some(revision);
            }
            let update = match watch.as_ref().map(Watch::take_latest) {
                Some(Ok(update)) => update,
                Some(Err(error)) => {
                    failure = Some(error);
                    break;
                }
                None => break,
            };
            let update = update.filter(|update| {
                update.generation == host.generation() && update.sequence > sequence
            });
            let sampled_at = update
                .as_ref()
                .map(|value| value.sampled_at)
                .unwrap_or_else(std::time::Instant::now);
            let should_apply = update.is_some()
                || applied_margins != Some(margins)
                || native.presentation_changed();
            if let Some(update) = update {
                sequence = update.sequence;

                if let Some(error) = update.terminal {
                    failure = Some(error);
                    break;
                }
            }
            if should_apply {
                match native.apply_host(host, sequence, margins) {
                    Ok(actual) => {
                        if let Some(error) = actual.terminal {
                            failure = Some(error);
                            break;
                        }
                        applied_margins = Some(margins);
                        let now_available =
                            actual.visibility_reason.is_none() && !actual.input_suspended;
                        if available && !now_available {
                            let focus = window
                                .update(cx, |_, window, cx| super::root::suspend(window, cx))
                                .ok()
                                .flatten();
                            if focus.is_some() {
                                saved_focus = focus;
                            }
                        } else if !available
                            && now_available
                            && mode == native_bridge::InputMode::Interactive
                            && let Some(focus) = saved_focus.take()
                        {
                            let _ = window.update(cx, |_, window, cx| window.focus(&focus, cx));
                        }
                        available = now_available;
                        let _ = weak.update(cx, |session, cx| {
                            if !runtime::is_open(&session.snapshot.phase) {
                                return;
                            }
                            let ready = session.snapshot.phase == OverlayPhase::Attaching;
                            let changed = ready
                                || session.snapshot.margins != margins
                                || session.snapshot.physical_overlay_rect
                                    != Some(actual.physical_overlay_rect)
                                || session.snapshot.physical_client_rect
                                    != Some(actual.physical_client_rect)
                                || session.snapshot.hidden_reason != actual.visibility_reason
                                || session.snapshot.input_suspended != actual.input_suspended;
                            session.snapshot.phase = OverlayPhase::Attached;
                            session.snapshot.physical_client_rect =
                                Some(actual.physical_client_rect);
                            session.snapshot.physical_overlay_rect =
                                Some(actual.physical_overlay_rect);
                            session.snapshot.margins = margins;
                            session.snapshot.hidden_reason = actual.visibility_reason;
                            session.snapshot.input_suspended = actual.input_suspended;
                            if changed {
                                session.snapshot.native_updates += 1;
                                session.snapshot.sample_to_apply = Some(sampled_at.elapsed());
                                session.publish(
                                    if ready {
                                        OverlayEventKind::Ready
                                    } else {
                                        OverlayEventKind::StateChanged
                                    },
                                    cx,
                                );
                            }
                        });
                    }
                    Err(error) => {
                        failure = Some(error);
                        break;
                    }
                }
            }
            if let Some(warning) = native.take_warning() {
                let _ = weak.update(cx, |session, cx| {
                    if runtime::is_open(&session.snapshot.phase) {
                        session.snapshot.error = Some(warning);
                        session.publish(OverlayEventKind::OperationFailed, cx);
                    }
                });
            }
            changed.wait().await;
        }
        let _ = weak.update(cx, |session, cx| session.request_close(cx));
        if let Some(binding) = binding.as_mut() {
            binding.hide();
            if let Err(error) = binding.unbind() {
                failure = Some(error);
            }
        }
        if let Some(watch) = watch.as_ref() {
            watch.stop();
        }
        drop(binding);
        let _ = window.update(cx, |_, window, _| window.remove_window());
        if let Some(watch) = watch.take() {
            use std::{
                future::{Future as _, poll_fn},
                pin::pin,
                task::Poll,
            };
            let mut cleanup = pin!(cx.background_spawn(async move { watch.finish() }));
            let mut deadline = pin!(cx.background_executor().timer(Duration::from_secs(2)));
            let completed = poll_fn(|cx| {
                if let Poll::Ready(result) = cleanup.as_mut().poll(cx) {
                    return Poll::Ready(Some(result));
                }
                if deadline.as_mut().poll(cx).is_ready() {
                    return Poll::Ready(None);
                }
                Poll::Pending
            })
            .await;
            let result = if let Some(result) = completed {
                result
            } else {
                let warning = native_bridge::failure(
                    native_bridge::ErrorKind::TrackingFailed,
                    "Native cleanup exceeded 2 seconds; still waiting for safe completion.",
                );
                eprintln!("{warning}");
                let _ = weak.update(cx, |session, cx| {
                    session.snapshot.error = Some(warning);
                    session.publish(OverlayEventKind::OperationFailed, cx);
                });
                cleanup.await
            };
            if let Err(error) = result {
                failure = Some(error);
            }
        }
        let _ = weak.update(cx, |session, cx| {
            session.snapshot.phase = OverlayPhase::Closed;
            session.snapshot.error = failure;
            session.window = None;
            session.publish(OverlayEventKind::Closed, cx);
        });
        cx.update(|cx| runtime::finished(id, cx));
    });
    session.update(cx, |session, _| session.task = Some(task));
}
