//! GPUI adapter for the UI-independent application state.

use std::{cell::Cell, rc::Rc};

use app_core::{AppState, Command, Effect, Snapshot, WorkStatus};
use gpui::{
    App, AppContext as _, Application, Bounds, Context, FocusHandle, Global, Render, Subscription,
    Task, Window, WindowBounds, WindowOptions, actions,
    prelude::{InteractiveElement as _, IntoElement, ParentElement as _, Styled as _},
    px, size,
};
use gpui_component::{
    ActiveTheme as _, Root,
    button::{Button, ButtonVariants as _},
    h_flex, v_flex,
};

#[cfg(any(test, feature = "test-support"))]
pub mod test_support;

const APP_TITLE: &str = "GPUI Agent Template";

actions!(template, [Increment, Reset, RunWork]);

#[derive(Clone, Copy, PartialEq, Eq)]
enum LaunchMode {
    Interactive,
    Smoke,
}

struct ApplicationLifecycle {
    _last_window_closed: Subscription,
}

impl Global for ApplicationLifecycle {}

fn install_last_window_quit_policy(cx: &mut App, mut request_quit: impl FnMut(&mut App) + 'static) {
    let last_window_closed = cx.on_window_closed(move |cx| {
        if cx.windows().is_empty() {
            request_quit(cx);
        }
    });
    cx.set_global(ApplicationLifecycle {
        _last_window_closed: last_window_closed,
    });
}

/// Launch the desktop application and its main window.
pub fn run() {
    run_with_mode(LaunchMode::Interactive);
}

/// Launch the production window in a finite native-backend self-check.
///
/// The check succeeds only after a real frame, a production typed Action, its
/// state projection, and a second frame complete before the process exits.
#[must_use]
pub fn run_smoke() -> bool {
    run_with_mode(LaunchMode::Smoke)
}

fn run_with_mode(mode: LaunchMode) -> bool {
    let smoke_succeeded = Rc::new(Cell::new(false));
    let smoke_result = smoke_succeeded.clone();

    Application::new().run(move |cx| {
        gpui_component::init(cx);
        install_last_window_quit_policy(cx, |cx| cx.quit());

        let bounds = Bounds::centered(None, size(px(920.0), px(620.0)), cx);
        let opened = cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..WindowOptions::default()
            },
            move |window, cx| {
                window.set_window_title(APP_TITLE);
                let view = cx.new(TemplateView::new);
                window.focus(&view.read(cx).focus_handle);

                if mode == LaunchMode::Smoke {
                    let action_view = view.clone();
                    let action_result = smoke_result.clone();
                    window.on_next_frame(move |window, cx| {
                        window.dispatch_action(Box::new(Increment), cx);

                        let verified_view = action_view.clone();
                        let verified_result = action_result.clone();
                        window.on_next_frame(move |window, cx| {
                            let snapshot = verified_view.read(cx).state.snapshot();
                            verified_result.set(snapshot.counter == 1);
                            window.remove_window();
                        });
                        window.refresh();
                    });
                    window.refresh();
                }

                cx.new(|cx| Root::new(view, window, cx))
            },
        );

        if let Err(error) = opened {
            eprintln!("failed to open the main window: {error}");
            cx.quit();
        }
    });

    mode == LaunchMode::Interactive || smoke_succeeded.get()
}

struct TemplateView {
    state: AppState,
    work_task: Option<Task<()>>,
    focus_handle: FocusHandle,
}

impl TemplateView {
    fn new(cx: &mut Context<'_, Self>) -> Self {
        Self {
            state: AppState::default(),
            work_task: None,
            focus_handle: cx.focus_handle(),
        }
    }

    fn dispatch(&mut self, command: Command, cx: &mut Context<'_, Self>) {
        let effect = self.state.dispatch(command);
        cx.notify();

        match effect {
            Effect::None => {}
            Effect::CancelWork => self.work_task = None,
            Effect::RunWork(request) => {
                let background_task = cx.background_spawn(async move { request.execute() });
                self.work_task = Some(cx.spawn(async move |this, cx| {
                    let result = background_task.await;
                    let _ = this.update(cx, |view, cx| {
                        view.state.dispatch(Command::WorkFinished(result));
                        cx.notify();
                    });
                }));
            }
        }
    }
}

impl Render for TemplateView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<'_, Self>) -> impl IntoElement {
        let snapshot = self.state.snapshot();
        let status = status_text(&snapshot);
        let status_is_running = matches!(snapshot.work_status, WorkStatus::Running { .. });

        v_flex()
            .id("template-root")
            .track_focus(&self.focus_handle)
            .on_action(cx.listener(|view: &mut Self, _: &Increment, _, cx| {
                view.dispatch(Command::Increment, cx);
            }))
            .on_action(cx.listener(|view: &mut Self, _: &Reset, _, cx| {
                view.dispatch(Command::Reset, cx);
            }))
            .on_action(cx.listener(|view: &mut Self, _: &RunWork, _, cx| {
                view.dispatch(Command::RunWork, cx);
            }))
            .size_full()
            .gap_6()
            .p_8()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                v_flex()
                    .gap_2()
                    .child(gpui::div().text_2xl().child(APP_TITLE))
                    .child(
                        gpui::div()
                            .text_sm()
                            .text_color(cx.theme().muted_foreground)
                            .child("Windows-first Rust + GPUI scaffold with agent guardrails."),
                    ),
            )
            .child(
                v_flex()
                    .gap_4()
                    .p_6()
                    .rounded_lg()
                    .border_1()
                    .border_color(cx.theme().border)
                    .bg(cx.theme().secondary)
                    .child(
                        h_flex()
                            .items_center()
                            .justify_between()
                            .child(gpui::div().child("Counter"))
                            .child(
                                gpui::div()
                                    .text_2xl()
                                    .child(snapshot.counter.to_string()),
                            ),
                    )
                    .child(
                        h_flex()
                            .gap_2()
                            .child(
                                gpui::div()
                                    .debug_selector(|| "increment-button".to_owned())
                                    .child(
                                        Button::new("increment")
                                            .primary()
                                            .label("Increment")
                                            .on_click(cx.listener(|_, _, window, cx| {
                                                window.dispatch_action(Box::new(Increment), cx);
                                            })),
                                    ),
                            )
                            .child(
                                gpui::div()
                                    .debug_selector(|| "reset-button".to_owned())
                                    .child(Button::new("reset").label("Reset").on_click(
                                        cx.listener(|_, _, window, cx| {
                                            window.dispatch_action(Box::new(Reset), cx);
                                        }),
                                    )),
                            )
                            .child(
                                gpui::div()
                                    .debug_selector(|| "run-work-button".to_owned())
                                    .child(
                                        Button::new("run-work")
                                            .label(if status_is_running {
                                                "Restart background work"
                                            } else {
                                                "Run background work"
                                            })
                                            .on_click(cx.listener(|_, _, window, cx| {
                                                window.dispatch_action(Box::new(RunWork), cx);
                                            })),
                                    ),
                            ),
                    )
                    .child(
                        gpui::div()
                            .px_3()
                            .py_2()
                            .rounded_md()
                            .bg(cx.theme().background)
                            .child(status),
                    ),
            )
            .child(
                gpui::div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child(
                        "The render path reads a snapshot only; the owned Task performs work off the UI thread.",
                    ),
            )
    }
}

fn status_text(snapshot: &Snapshot) -> String {
    match snapshot.work_status {
        WorkStatus::Idle => "Background status: idle".to_owned(),
        WorkStatus::Running { revision } => {
            format!("Background status: running revision {revision}")
        }
        WorkStatus::Succeeded { revision, value } => {
            format!("Background status: revision {revision} completed with {value:#018x}")
        }
    }
}

#[cfg(test)]
mod projection_tests {
    use super::*;

    #[test]
    fn status_projection_contains_revision_and_value() {
        let snapshot = Snapshot {
            counter: 3,
            work_status: WorkStatus::Succeeded {
                revision: 9,
                value: 0x2a,
            },
        };

        assert_eq!(
            status_text(&snapshot),
            "Background status: revision 9 completed with 0x000000000000002a"
        );
    }
}

#[cfg(test)]
mod tests;
