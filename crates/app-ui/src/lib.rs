//! GPUI adapter for the UI-independent application state.

use app_core::{AppState, Command, Effect, Snapshot, WorkStatus};
use gpui::{
    AppContext as _, Application, Bounds, Context, Render, Task, Window, WindowBounds,
    WindowOptions,
    prelude::{InteractiveElement as _, IntoElement, ParentElement as _, Styled as _},
    px, size,
};
use gpui_component::{
    ActiveTheme as _, Root,
    button::{Button, ButtonVariants as _},
    h_flex, v_flex,
};

const APP_TITLE: &str = "GPUI Agent Template";

/// Launch the desktop application and its main window.
pub fn run() {
    Application::new().run(|cx| {
        gpui_component::init(cx);

        let bounds = Bounds::centered(None, size(px(920.0), px(620.0)), cx);
        let opened = cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..WindowOptions::default()
            },
            |window, cx| {
                window.set_window_title(APP_TITLE);
                let view = cx.new(|_| TemplateView::default());
                cx.new(|cx| Root::new(view, window, cx))
            },
        );

        if let Err(error) = opened {
            eprintln!("failed to open the main window: {error}");
            cx.quit();
        }
    });
}

#[derive(Default)]
struct TemplateView {
    state: AppState,
    work_task: Option<Task<()>>,
}

impl TemplateView {
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
                                Button::new("increment")
                                    .primary()
                                    .label("Increment")
                                    .on_click(cx.listener(|view, _, _, cx| {
                                        view.dispatch(Command::Increment, cx);
                                    })),
                            )
                            .child(
                                Button::new("reset").label("Reset").on_click(cx.listener(
                                    |view, _, _, cx| {
                                        view.dispatch(Command::Reset, cx);
                                    },
                                )),
                            )
                            .child(
                                Button::new("run-work")
                                    .label(if status_is_running {
                                        "Restart background work"
                                    } else {
                                        "Run background work"
                                    })
                                    .on_click(cx.listener(|view, _, _, cx| {
                                        view.dispatch(Command::RunWork, cx);
                                    })),
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
mod tests {
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
