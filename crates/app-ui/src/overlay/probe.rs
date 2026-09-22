//! Bounded native acceptance probe through the production facade.
use super::*;
use crate::overlay_demo::content::DemoContent;
use gpui_kit::{
    AsyncApp, Context, EntityInputHandler as _, Focusable, Render, Window, WindowOptions,
    prelude::*,
};
use std::{
    cell::Cell,
    rc::Rc,
    time::{Duration, Instant},
};

struct Owner;
impl Render for Owner {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        gpui_kit::div().child("Overlay probe owner")
    }
}

async fn wait_phase(
    overlay: &OverlayWindow<DemoContent>,
    expected: OverlayPhase,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let state = cx
            .update(|cx| overlay.snapshot(cx))
            .map_err(|error| error.to_string())?;
        if state.phase == expected {
            return Ok(());
        }
        if state.phase == OverlayPhase::Closed || Instant::now() >= deadline {
            return Err(format!("expected {expected:?}, observed {state:?}"));
        }
        cx.background_executor()
            .timer(Duration::from_millis(16))
            .await;
    }
}

async fn exercise(
    owner: gpui_kit::AnyWindowHandle,
    host: HostWindowId,
    cx: &mut AsyncApp,
) -> Result<(), String> {
    let stress = std::env::args().any(|arg| arg == "--stress");
    let interactive = std::env::args().any(|arg| arg == "--interactive");
    let ime = std::env::args().any(|arg| arg == "--ime");
    let close_case = std::env::args().find(|arg| {
        matches!(
            arg.as_str(),
            "--host-exit" | "--owner-close" | "--external-close"
        )
    });
    let baseline = native_bridge::resources();
    let started = Instant::now();
    for cycle in 0..if stress { 100 } else { 1 } {
        let cycle_started = Instant::now();
        let mode = if interactive {
            InputMode::Interactive
        } else {
            InputMode::Passthrough
        };
        let overlay = cx
            .update(|cx| {
                open_window(
                    host,
                    OverlayOptions {
                        owner,
                        input_mode: mode,
                    },
                    move |window, cx| cx.new(|cx| DemoContent::new(mode, window, cx)),
                    cx,
                )
            })
            .map_err(|error| error.to_string())?;
        let opened = Instant::now();
        let weak_content = cx
            .update(|cx| overlay.content(cx))
            .map_err(|error| error.to_string())?
            .downgrade();
        let closed_events = Rc::new(Cell::new(0));
        let observed_closed = closed_events.clone();
        let last_revision = Rc::new(Cell::new(0));
        let revisions_valid = Rc::new(Cell::new(true));
        let valid = revisions_valid.clone();
        let content_events = weak_content.clone();
        let saw_composition = Rc::new(Cell::new(false));
        let composition_hidden = Rc::new(Cell::new(false));
        let composing_events = saw_composition.clone();
        let hidden_events = composition_hidden.clone();
        let _subscription = cx.update(|cx| {
            overlay.observe(cx, move |event, cx| {
                if ime
                    && composing_events.get()
                    && event.snapshot.phase == OverlayPhase::Attached
                    && event.snapshot.hidden_reason.is_some()
                {
                    hidden_events.set(true);
                }
                if event.snapshot.revision < last_revision.replace(event.snapshot.revision) {
                    valid.set(false);
                }
                if event.kind == OverlayEventKind::Closed {
                    observed_closed.set(observed_closed.get() + 1);
                }
                if event.snapshot.phase == OverlayPhase::Attached {
                    let _ = content_events
                        .update(cx, |content, cx| content.apply(event.snapshot.clone(), cx));
                }
                if !stress {
                    println!("PROBE_EVENT {:?} {:?}", event.kind, event.snapshot);
                }
            })
        });
        wait_phase(&overlay, OverlayPhase::Attached, cx).await?;
        let attached = Instant::now();
        if !stress && close_case.is_none() {
            let painted = Rc::new(Cell::new(false));
            let frame = painted.clone();
            cx.update(|cx| {
                overlay.update(cx, |_, window, _| {
                    window.on_next_frame(move |_, _| frame.set(true));
                    window.refresh();
                })
            })
            .map_err(|error| error.to_string())?;
            if ime {
                let deadline = Instant::now() + Duration::from_secs(7);
                let mut was_composing = false;
                let mut composition_sessions = 0;
                while Instant::now() < deadline {
                    let composing = cx
                        .update(|cx| {
                            overlay.update(cx, |content, window, cx| {
                                content.input.update(cx, |input, cx| {
                                    input.marked_text_range(window, cx).is_some()
                                })
                            })
                        })
                        .map_err(|error| error.to_string())?;
                    saw_composition.set(saw_composition.get() || composing);
                    if composing && !was_composing {
                        composition_sessions += 1;
                    }
                    was_composing = composing;
                    cx.background_executor()
                        .timer(Duration::from_millis(25))
                        .await;
                }
                if composition_sessions < 2 || was_composing {
                    return Err(format!(
                        "Expected canceled and committed IME sessions, observed {composition_sessions}, still_composing={was_composing}"
                    ));
                }
            } else {
                cx.background_executor().timer(Duration::from_secs(7)).await;
            }
            if !painted.get() {
                return Err(
                    "No visible GPUI frame; interactive desktop/foreground required.".into(),
                );
            }
            let visible = cx
                .update(|cx| overlay.snapshot(cx))
                .map_err(|error| error.to_string())?
                .hidden_reason
                .is_none();
            if !visible {
                return Err("Overlay never reached visible foreground acceptance state.".into());
            }
            if interactive {
                let (count, text, focused) = cx
                    .update(|cx| {
                        overlay.update(cx, |content, window, cx| {
                            (
                                content.count,
                                content.input.read(cx).value().to_string(),
                                content.input.read(cx).focus_handle(cx).is_focused(window),
                            )
                        })
                    })
                    .map_err(|error| error.to_string())?;
                let expected = if ime { "你好" } else { "test" };
                if count < 1 || text != expected {
                    return Err(format!(
                        "Real input mismatch: count={count}, text={text:?}, input_focused={focused}; expected count>=1 and text={expected:?}."
                    ));
                }
                if ime {
                    let state = cx
                        .update(|cx| overlay.snapshot(cx))
                        .map_err(|error| error.to_string())?;
                    if !saw_composition.get()
                        || composition_hidden.get()
                        || state.input_mode != InputMode::Interactive
                    {
                        return Err(format!(
                            "IME composition contract failed: observed={}, hidden={}, mode={:?}",
                            saw_composition.get(),
                            composition_hidden.get(),
                            state.input_mode
                        ));
                    }
                    println!("PROBE_IME_OK composition_observed=true text=你好");
                }
                println!("PROBE_CONTENT_INPUT_OK");
                cx.update(|cx| overlay.set_input_mode(InputMode::Passthrough, cx))
                    .map_err(|error| error.to_string())?;
            }
            cx.background_executor().timer(Duration::from_secs(3)).await;
        }
        if close_case.is_none() {
            cx.update(|cx| overlay.close(cx))
                .map_err(|error| error.to_string())?;
        }
        wait_phase(&overlay, OverlayPhase::Closed, cx).await?;
        if stress && cycle < 3 {
            println!(
                "OVERLAY_CYCLE_TIMING open_ms={} attach_ms={} close_ms={}",
                opened.duration_since(cycle_started).as_millis(),
                attached.duration_since(opened).as_millis(),
                attached.elapsed().as_millis()
            );
        }
        let final_state = cx
            .update(|cx| overlay.snapshot(cx))
            .map_err(|error| error.to_string())?;
        let expected_error = if close_case.as_deref() == Some("--host-exit") {
            Some(ErrorKind::HostGone)
        } else {
            None
        };
        if final_state.error.as_ref().map(|error| error.kind) != expected_error
            || closed_events.get() != 1
            || !revisions_valid.get()
            || weak_content.upgrade().is_some()
        {
            return Err(format!(
                "Invalid terminal lifecycle: {final_state:?}, closed={}",
                closed_events.get()
            ));
        }
        if native_bridge::resources() != baseline {
            return Err(format!(
                "Native resource leak after cycle {cycle}: {:?}",
                native_bridge::resources()
            ));
        }
        if stress && cycle % 10 == 9 {
            println!(
                "OVERLAY_STRESS_PROGRESS cycles={} elapsed_ms={}",
                cycle + 1,
                started.elapsed().as_millis()
            );
        }
    }
    println!(
        "OVERLAY_NATIVE_{}_OK resources={baseline:?}",
        if stress {
            "STRESS_100"
        } else if close_case.is_some() {
            "LIFECYCLE"
        } else {
            "SMOKE"
        }
    );
    Ok(())
}

async fn exercise_preview(cx: &mut AsyncApp) -> Result<(), String> {
    use crate::overlay_demo::PreviewSurface;
    use gpui_kit::component::Root;
    let mut content = None;
    let preview = cx
        .update(|cx| {
            let bounds = gpui_kit::Bounds::centered(
                None,
                gpui_kit::size(gpui_kit::px(900.0), gpui_kit::px(650.0)),
                cx,
            );
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(gpui_kit::WindowBounds::Windowed(bounds)),
                    ..WindowOptions::default()
                },
                |window, cx| {
                    let view = cx.new(|cx| DemoContent::new(InputMode::Interactive, window, cx));
                    content = Some(view.clone());
                    let surface = cx.new(|_| PreviewSurface(view));
                    cx.new(|cx| Root::new(surface, window, cx))
                },
            )
        })
        .map_err(|error| error.to_string())?;
    let content = content.ok_or("Preview content was not created")?;
    let outcome = async {
        let deadline = Instant::now() + Duration::from_secs(7);
        let mut was_composing = false;
        let mut sessions = 0;
        while Instant::now() < deadline {
            let composing = cx
                .update(|cx| {
                    preview.update(cx, |_, window, cx| {
                        content.update(cx, |view, cx| {
                            view.input.update(cx, |input, cx| {
                                input.marked_text_range(window, cx).is_some()
                            })
                        })
                    })
                })
                .map_err(|error| error.to_string())?;
            if composing && !was_composing {
                sessions += 1;
            }
            was_composing = composing;
            cx.background_executor()
                .timer(Duration::from_millis(25))
                .await;
        }
        let (count, text) = cx.update(|cx| {
            let view = content.read(cx);
            (view.count, view.input.read(cx).value().to_string())
        });
        if count != 1 || text != "你好" || sessions < 2 || was_composing {
            return Err(format!(
                "Ordinary preview IME failed: count={count}, text={text:?}, sessions={sessions}, still_composing={was_composing}"
            ));
        }
        println!("PROBE_IME_PREVIEW_OK composition_sessions={sessions} text=你好");
        Ok(())
    }
    .await;
    cx.update(|cx| preview.update(cx, |_, window, _| window.remove_window()))
        .map_err(|error| error.to_string())?;
    outcome
}

#[must_use]
pub fn run_feasibility_probe() -> bool {
    let succeeded = Rc::new(Cell::new(false));
    let result = succeeded.clone();
    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .run(move |cx| {
            gpui_kit::init(cx);
            init(cx);
            let owner = cx.open_window(
                WindowOptions {
                    show: false,
                    focus: false,
                    ..Default::default()
                },
                |_, cx| cx.new(|_| Owner),
            );
            let Ok(owner) = owner else {
                eprintln!("PROBE_OWNER_FAILED");
                cx.quit();
                return;
            };
            let Some(raw) = std::env::var("OVERLAY_PROBE_HOST")
                .ok()
                .and_then(|value| value.parse().ok())
            else {
                eprintln!("PROBE_HOST_REQUIRED");
                cx.quit();
                return;
            };
            let resolved = resolve_host(RawHostHandle(raw), cx);
            cx.spawn(async move |cx| {
                let outcome = match resolved.await {
                    Ok(_) if std::env::args().any(|arg| arg == "--ime-preview") => {
                        exercise_preview(cx).await
                    }
                    Ok(host) => exercise(owner.into(), host, cx).await,
                    Err(error) => Err(error.to_string()),
                };
                let passed = outcome.is_ok();
                if let Err(error) = outcome {
                    eprintln!("OVERLAY_NATIVE_FAILED: {error}");
                }
                cx.update(|cx| {
                    let _ = owner.update(cx, |_, window, _| window.remove_window());
                    prepare_quit(cx, move |cx| {
                        println!("PROBE_CLEANUP_COMPLETE");
                        result.set(passed);
                        cx.quit();
                    });
                });
            })
            .detach();
        });
    succeeded.get()
}
