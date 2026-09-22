//! Window selection demo. All host operations go through the overlay facade.
pub(crate) mod content;
use crate::{
    LaunchIdentity,
    overlay::{
        self, HostInfo, HostWindowId, InputMode, OverlayEvent, OverlayEventKind, OverlayOptions,
        OverlayPhase, OverlaySnapshot, OverlayWindow,
    },
};
use content::DemoContent;
use gpui_kit::component::{
    ActiveTheme as _, Disableable as _, Root,
    button::{Button, ButtonVariants as _},
    h_flex,
    input::{Input, InputEvent, InputState},
    v_flex,
};
use gpui_kit::{
    AnyWindowHandle, AppContext as _, Context, Entity, FocusHandle, Render, Subscription, Task,
    Window, actions, div, prelude::*,
};

actions!(
    overlay_demo,
    [
        RefreshHosts,
        AttachSelected,
        DetachHost,
        ToggleMode,
        PreviewContent,
        SelectNext,
        SelectPrevious
    ]
);

enum LoadState {
    Loading,
    Ready,
    Failed(String),
}

pub(crate) struct OverlayDemo {
    identity: LaunchIdentity,
    owner: AnyWindowHandle,
    focus: FocusHandle,
    filter: Entity<InputState>,
    _filter_events: Subscription,
    hosts: Vec<HostInfo>,
    skipped: usize,
    load: LoadState,
    refresh_revision: u64,
    refresh_task: Option<Task<()>>,
    selected: Option<HostWindowId>,
    active: Option<OverlayWindow<DemoContent>>,
    session_events: Option<Subscription>,
    snapshot: Option<OverlaySnapshot>,
    pending_host: Option<HostWindowId>,
    requested_mode: Option<InputMode>,
    error: Option<String>,
}

impl OverlayDemo {
    pub(crate) fn new(
        identity: LaunchIdentity,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let filter = cx.new(|cx| InputState::new(window, cx).placeholder("按窗口标题或 PID 搜索"));
        let filter_events = cx.subscribe(&filter, |_, _, _: &InputEvent, cx| cx.notify());
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        cx.bind_keys([
            gpui_kit::KeyBinding::new("down", SelectNext, Some("OverlayDemo")),
            gpui_kit::KeyBinding::new("up", SelectPrevious, Some("OverlayDemo")),
            gpui_kit::KeyBinding::new("enter", AttachSelected, Some("OverlayDemo")),
            gpui_kit::KeyBinding::new("f5", RefreshHosts, Some("OverlayDemo")),
        ]);
        let mut view = Self {
            identity,
            owner: window.window_handle(),
            focus,
            filter,
            _filter_events: filter_events,
            hosts: Vec::new(),
            skipped: 0,
            load: LoadState::Ready,
            refresh_revision: 0,
            refresh_task: None,
            selected: None,
            active: None,
            session_events: None,
            snapshot: None,
            pending_host: None,
            requested_mode: None,
            error: None,
        };
        view.refresh(cx);
        view
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        self.refresh_revision += 1;
        let revision = self.refresh_revision;
        self.load = LoadState::Loading;
        let task = overlay::list_hosts(cx);
        self.refresh_task = Some(cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |view, cx| {
                if view.refresh_revision != revision {
                    return;
                }
                match result {
                    Ok(list) => {
                        view.selected = view.selected.and_then(|selected| {
                            list.hosts
                                .iter()
                                .find(|host| {
                                    host.id.raw() == selected.raw()
                                        && host.id.process_id() == selected.process_id()
                                })
                                .map(|host| host.id)
                        });
                        view.hosts = list.hosts;
                        view.skipped = list.skipped;
                        view.load = LoadState::Ready;
                    }
                    Err(error) => view.load = LoadState::Failed(error.to_string()),
                }
                cx.notify();
            });
        }));
        cx.notify();
    }
    fn filtered(&self, cx: &gpui_kit::App) -> Vec<HostInfo> {
        let query = self.filter.read(cx).value().to_lowercase();
        self.hosts
            .iter()
            .filter(|host| {
                query.is_empty()
                    || host.title.to_lowercase().contains(&query)
                    || host.id.process_id().to_string().contains(&query)
            })
            .cloned()
            .collect()
    }
    fn select(&mut self, host: HostWindowId, cx: &mut Context<Self>) {
        self.selected = Some(host);
        cx.notify();
    }
    fn move_selection(&mut self, step: isize, cx: &mut Context<Self>) {
        let hosts = self.filtered(cx);
        if hosts.is_empty() {
            return;
        }
        let current = self
            .selected
            .and_then(|selected| hosts.iter().position(|host| host.id == selected));
        let next = match current {
            Some(index) => (index as isize + step).clamp(0, hosts.len() as isize - 1) as usize,
            None => 0,
        };
        self.select(hosts[next].id, cx);
    }
    fn busy(&self) -> bool {
        self.snapshot.as_ref().is_some_and(|state| {
            matches!(state.phase, OverlayPhase::Attaching | OverlayPhase::Closing)
        })
    }
    fn attach_selected(&mut self, cx: &mut Context<Self>) {
        if self.busy() {
            return;
        }
        let Some(host) = self.selected else {
            return;
        };
        if let Some(active) = &self.active {
            if self
                .snapshot
                .as_ref()
                .is_some_and(|state| state.host.raw() == host.raw())
            {
                return;
            }
            self.pending_host = Some(host);
            if let Err(error) = active.close(cx) {
                self.error = Some(error.to_string());
            }
        } else {
            self.attach(host, cx);
        }
        cx.notify();
    }
    fn attach(&mut self, host: HostWindowId, cx: &mut Context<Self>) {
        self.error = None;
        let opened = overlay::open_window(
            host,
            OverlayOptions {
                owner: self.owner,
                input_mode: InputMode::Passthrough,
            },
            |window, cx| cx.new(|cx| DemoContent::new(InputMode::Passthrough, window, cx)),
            cx,
        );
        match opened {
            Ok(overlay) => {
                self.snapshot = overlay.snapshot(cx).ok();
                let weak = cx.entity().downgrade();
                let events = overlay.observe(cx, move |event, cx| {
                    // Defer the initial replay too: attach currently borrows this view.
                    let weak = weak.clone();
                    cx.defer(move |cx| {
                        let _ = weak.update(cx, |view, cx| view.event(event, cx));
                    });
                });
                self.active = Some(overlay);
                self.session_events = Some(events);
            }
            Err(error) => {
                self.error = Some(error.to_string());
                self.active = None;
            }
        }
        cx.notify();
    }
    fn event(&mut self, event: OverlayEvent, cx: &mut Context<Self>) {
        if self.snapshot.as_ref().is_some_and(|state| {
            state.session_id != event.snapshot.session_id
                || state.revision > event.snapshot.revision
        }) {
            return;
        }
        if let Some(active) = &self.active {
            let snapshot = event.snapshot.clone();
            let _ = active.update(cx, |content, _, cx| content.apply(snapshot, cx));
        }
        if matches!(
            event.kind,
            OverlayEventKind::ModeChanged | OverlayEventKind::OperationFailed
        ) {
            self.requested_mode = None;
        }
        self.error = event.snapshot.error.as_ref().map(ToString::to_string);
        self.snapshot = Some(event.snapshot);
        if event.kind == OverlayEventKind::Closed {
            self.active = None;
            self.session_events = None;
            self.requested_mode = None;
            if let Some(host) = self.pending_host.take() {
                self.attach(host, cx);
            }
        }
        cx.notify();
    }
    fn detach(&mut self, cx: &mut Context<Self>) {
        self.pending_host = None;
        if let Some(active) = &self.active
            && let Err(error) = active.close(cx)
        {
            self.error = Some(error.to_string());
        }
        cx.notify();
    }
    fn toggle_mode(&mut self, cx: &mut Context<Self>) {
        if self.busy() {
            return;
        }
        if let (Some(active), Some(snapshot)) = (&self.active, &self.snapshot) {
            let target = if snapshot.input_mode == InputMode::Passthrough {
                InputMode::Interactive
            } else {
                InputMode::Passthrough
            };
            match active.set_input_mode(target, cx) {
                Ok(()) => self.requested_mode = Some(target),
                Err(error) => self.error = Some(error.to_string()),
            }
        }
        cx.notify();
    }
    fn preview(&mut self, cx: &mut Context<Self>) {
        let opened = cx.open_window(gpui_kit::WindowOptions::default(), |window, cx| {
            window.set_window_title("相同内容 · 普通 Kit 窗口");
            let content = cx.new(|cx| DemoContent::new(InputMode::Interactive, window, cx));
            let surface = cx.new(|_| PreviewSurface(content));
            cx.new(|cx| Root::new(surface, window, cx))
        });
        if let Err(error) = opened {
            self.error = Some(error.to_string());
            cx.notify();
        }
    }
}

impl Render for OverlayDemo {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let hosts = self.filtered(cx);
        let selected_text = self
            .selected
            .map(|host| {
                format!(
                    "待附着选择：PID {} · HWND 0x{:X}",
                    host.process_id(),
                    host.raw()
                )
            })
            .unwrap_or_else(|| "从列表选择一个宿主；↑/↓ 选择，Enter 附着，F5 刷新。".into());
        let status = self
            .snapshot
            .as_ref()
            .map(|state| {
                format!(
                    "当前会话：{:?} · {:?} · PID {} · HWND 0x{:X}\n{:?}",
                    state.phase,
                    state.input_mode,
                    state.host.process_id(),
                    state.host.raw(),
                    state.hidden_reason
                )
            })
            .unwrap_or_else(|| "尚未附着".into());
        v_flex()
            .id("overlay-demo")
            .key_context("OverlayDemo")
            .track_focus(&self.focus)
            .size_full()
            .p_6()
            .gap_3()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .on_action(cx.listener(|view, _: &RefreshHosts, _, cx| view.refresh(cx)))
            .on_action(cx.listener(|view, _: &AttachSelected, _, cx| view.attach_selected(cx)))
            .on_action(cx.listener(|view, _: &DetachHost, _, cx| view.detach(cx)))
            .on_action(cx.listener(|view, _: &ToggleMode, _, cx| view.toggle_mode(cx)))
            .on_action(cx.listener(|view, _: &PreviewContent, _, cx| view.preview(cx)))
            .on_action(cx.listener(|view, _: &SelectNext, _, cx| view.move_selection(1, cx)))
            .on_action(cx.listener(|view, _: &SelectPrevious, _, cx| view.move_selection(-1, cx)))
            .child(div().text_2xl().child(format!(
                "{} · Windows Overlay",
                self.identity.display_name()
            )))
            .child(
                div()
                    .text_sm()
                    .child("控制窗口在前台时 Overlay 会隐藏。附着或切换模式后，请切回宿主查看。"),
            )
            .child(
                h_flex().gap_2().child(Input::new(&self.filter)).child(
                    Button::new("overlay-refresh")
                        .label("刷新")
                        .on_click(|_, window, cx| {
                            window.dispatch_action(Box::new(RefreshHosts), cx)
                        }),
                ),
            )
            .child(div().text_sm().child(match &self.load {
                LoadState::Loading => "正在枚举窗口…".into(),
                LoadState::Failed(error) => format!("枚举失败：{error}。请刷新重试。"),
                LoadState::Ready => {
                    format!("{} 个匹配窗口 · 跳过 {} 项", hosts.len(), self.skipped)
                }
            }))
            .child(
                v_flex()
                    .id("host-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .gap_1()
                    .when(hosts.is_empty(), |list| {
                        list.child("没有匹配窗口。请打开普通应用，清除搜索条件后刷新。")
                    })
                    .children(hosts.into_iter().map(|host| {
                        let selected = self.selected == Some(host.id);
                        let id = host.id;
                        Button::new(("host", id.raw()))
                            .label(format!(
                                "{} · PID {} · 0x{:X}",
                                if host.title.is_empty() {
                                    "无标题窗口"
                                } else {
                                    &host.title
                                },
                                id.process_id(),
                                id.raw()
                            ))
                            .when(selected, |button| button.primary())
                            .w_full()
                            .on_click(cx.listener(move |view, _, window, cx| {
                                view.select(id, cx);
                                window.focus(&view.focus, cx);
                            }))
                    })),
            )
            .child(div().text_sm().child(selected_text))
            .child(
                h_flex()
                    .gap_2()
                    .child(
                        Button::new("overlay-attach")
                            .primary()
                            .label(if self.busy() {
                                "处理中…"
                            } else {
                                "附着 / 切换宿主"
                            })
                            .disabled(self.busy() || self.selected.is_none())
                            .on_click(|_, window, cx| {
                                window.dispatch_action(Box::new(AttachSelected), cx)
                            }),
                    )
                    .child(
                        Button::new("overlay-detach")
                            .label("分离")
                            .disabled(self.active.is_none())
                            .on_click(|_, window, cx| {
                                window.dispatch_action(Box::new(DetachHost), cx)
                            }),
                    )
                    .child(
                        Button::new("overlay-mode")
                            .label(if self.requested_mode.is_some() {
                                "正在切换…"
                            } else {
                                "切换 HUD / 交互"
                            })
                            .disabled(
                                self.active.is_none()
                                    || self.busy()
                                    || self.requested_mode.is_some(),
                            )
                            .on_click(|_, window, cx| {
                                window.dispatch_action(Box::new(ToggleMode), cx)
                            }),
                    )
                    .child(
                        Button::new("overlay-preview")
                            .label("普通窗口预览")
                            .on_click(|_, window, cx| {
                                window.dispatch_action(Box::new(PreviewContent), cx)
                            }),
                    ),
            )
            .child(div().text_sm().child(status))
            .when_some(self.error.clone(), |view, error| {
                view.child(
                    div()
                        .text_color(cx.theme().danger)
                        .text_sm()
                        .child(format!("{error} · 可刷新、重选或重试附着。")),
                )
            })
    }
}

struct PreviewSurface(Entity<DemoContent>);
impl Render for PreviewSurface {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let sheet = Root::render_sheet_layer(window, cx);
        let dialog = Root::render_dialog_layer(window, cx);
        let notification = Root::render_notification_layer(window, cx);
        div()
            .size_full()
            .child(self.0.clone())
            .children(sheet)
            .children(dialog)
            .children(notification)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::overlay::{HostList, testing::Backend};
    use gpui_kit::component::WindowExt as _;
    use gpui_kit::{TestAppContext, VisualTestContext, test::TestWindowExt as _};

    fn setup(cx: &mut TestAppContext) -> (Entity<OverlayDemo>, &mut VisualTestContext, Backend) {
        crate::test_support::init_test_app(cx);
        let backend = Backend::default();
        *backend
            .hosts
            .lock()
            .unwrap_or_else(|error| panic!("{error}")) = HostList {
            hosts: vec![
                HostInfo {
                    id: HostWindowId::fixture(41),
                    title: "First host".into(),
                },
                HostInfo {
                    id: HostWindowId::fixture(42),
                    title: "Second host".into(),
                },
            ],
            skipped: 2,
        };
        cx.set_global(backend.clone());
        let (view, cx) = cx.add_window_view(|window, cx| {
            OverlayDemo::new(LaunchIdentity::new("Fixture"), window, cx)
        });
        cx.run_until_parked();
        (view, cx, backend)
    }
    fn tick(cx: &mut VisualTestContext) {
        cx.run_until_parked();
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(64));
        cx.run_until_parked();
    }

    #[gpui_kit::test]
    fn same_business_components_work_in_preview_and_overlay(cx: &mut TestAppContext) {
        crate::test_support::init_test_app(cx);
        cx.set_global(Backend::default());
        let owner = cx.add_window(|_, _| PreviewSurfacePlaceholder);
        for in_overlay in [false, true] {
            let (window, content, overlay) = if in_overlay {
                let overlay = cx
                    .update(|cx| {
                        crate::overlay::open_window(
                            HostWindowId::fixture(78),
                            OverlayOptions {
                                owner: owner.into(),
                                input_mode: InputMode::Interactive,
                            },
                            |window, cx| {
                                cx.new(|cx| DemoContent::new(InputMode::Interactive, window, cx))
                            },
                            cx,
                        )
                    })
                    .unwrap_or_else(|error| panic!("{error}"));
                cx.run_until_parked();
                let content = cx
                    .update(|cx| overlay.content(cx))
                    .unwrap_or_else(|error| panic!("{error}"));
                let window = cx
                    .update(|cx| overlay.update(cx, |_, window, _| window.window_handle()))
                    .unwrap_or_else(|error| panic!("{error}"));
                (window, content, Some(overlay))
            } else {
                let mut content = None;
                let window = cx
                    .update(|cx| {
                        cx.open_window(Default::default(), |window, cx| {
                            let view =
                                cx.new(|cx| DemoContent::new(InputMode::Interactive, window, cx));
                            content = Some(view.clone());
                            let surface = cx.new(|_| PreviewSurface(view));
                            cx.new(|cx| Root::new(surface, window, cx))
                        })
                    })
                    .unwrap_or_else(|error| panic!("{error}"));
                (
                    window.into(),
                    content.unwrap_or_else(|| panic!("preview content missing")),
                    None,
                )
            };
            window
                .update(cx, |_, window, cx| {
                    window.render_frame(cx);
                    println!(
                        "DEMO_TARGETS overlay={in_overlay} button={:?} input={:?}",
                        window.find("overlay-count").bounds(),
                        window.find("overlay-input").bounds()
                    );
                    window.click("overlay-count", cx);
                    window.click("overlay-input", cx);
                    window.input("shared text", cx);
                })
                .unwrap_or_else(|error| panic!("{error}"));
            assert_eq!(content.read_with(cx, |view, _| view.count), 1);
            assert_eq!(
                content.read_with(cx, |view, cx| view.input.read(cx).value().to_string()),
                "shared text"
            );
            window
                .update(cx, |_, window, cx| {
                    window.click("overlay-dialog", cx);
                })
                .unwrap_or_else(|error| panic!("{error}"));
            cx.run_until_parked();
            window
                .update(cx, |_, window, cx| {
                    assert!(window.has_active_dialog(cx));
                    window.press("escape", cx);
                })
                .unwrap_or_else(|error| panic!("{error}"));
            cx.run_until_parked();
            window
                .update(cx, |_, window, cx| assert!(!window.has_active_dialog(cx)))
                .unwrap_or_else(|error| panic!("{error}"));
            if let Some(overlay) = overlay {
                assert_eq!(
                    cx.update(|cx| overlay.snapshot(cx))
                        .map(|state| state.input_mode)
                        .ok(),
                    Some(InputMode::Interactive)
                );
                window
                    .update(cx, |_, window, cx| window.click("overlay-menu", cx))
                    .unwrap_or_else(|error| panic!("{error}"));
                cx.run_until_parked();
                assert!(cx.update(|cx| gpui_kit::base::GlobalState::is_in_deferred_context(cx)));
                assert!(
                    cx.update(|cx| overlay.set_input_mode(InputMode::Passthrough, cx))
                        .is_ok()
                );
                cx.run_until_parked();
                window
                    .update(cx, |_, window, cx| window.render_frame(cx))
                    .unwrap_or_else(|error| panic!("{error}"));
                assert!(!cx.update(|cx| gpui_kit::base::GlobalState::is_in_deferred_context(cx)));
                assert!(cx.update(|cx| overlay.close(cx)).is_ok());
            } else {
                assert!(
                    window
                        .update(cx, |_, window, _| window.remove_window())
                        .is_ok()
                );
            }
            cx.run_until_parked();
        }
    }

    struct PreviewSurfacePlaceholder;
    impl Render for PreviewSurfacePlaceholder {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
        }
    }

    #[gpui_kit::test]
    fn keyboard_selection_and_real_attach_button_share_one_session(cx: &mut TestAppContext) {
        let (view, cx, _) = setup(cx);
        cx.dispatch_action(SelectNext);
        cx.update(|window, app| window.click("overlay-attach", app));
        cx.dispatch_action(AttachSelected);
        tick(cx);
        assert_eq!(
            view.read_with(cx, |view, _| view
                .snapshot
                .as_ref()
                .map(|state| state.phase.clone())),
            Some(OverlayPhase::Attached)
        );
        assert_eq!(cx.update(|_, app| app.windows().len()), 2);
        cx.dispatch_action(DetachHost);
        tick(cx);
        assert!(view.read_with(cx, |view, _| view.active.is_none()));
    }

    #[gpui_kit::test]
    fn switching_host_waits_for_old_content_release(cx: &mut TestAppContext) {
        let (view, cx, _) = setup(cx);
        cx.dispatch_action(SelectNext);
        cx.dispatch_action(AttachSelected);
        tick(cx);
        let old_content = view.read_with(cx, |view, app| {
            view.active
                .as_ref()
                .and_then(|active| active.content(app).ok())
                .map(|content| content.downgrade())
        });
        cx.dispatch_action(SelectNext);
        cx.dispatch_action(AttachSelected);
        tick(cx);
        tick(cx);
        assert_eq!(
            view.read_with(cx, |view, _| view
                .snapshot
                .as_ref()
                .map(|state| state.host.raw())),
            Some(42)
        );
        assert!(old_content.is_some_and(|content| content.upgrade().is_none()));
        assert_eq!(cx.update(|_, app| app.windows().len()), 2);
        cx.dispatch_action(DetachHost);
        tick(cx);
    }

    #[gpui_kit::test]
    fn refresh_preserves_valid_selection_and_clears_removed_selection(cx: &mut TestAppContext) {
        let (view, cx, backend) = setup(cx);
        cx.dispatch_action(SelectNext);
        cx.dispatch_action(RefreshHosts);
        tick(cx);
        assert_eq!(
            view.read_with(cx, |view, _| view.selected.map(HostWindowId::raw)),
            Some(41)
        );
        backend
            .hosts
            .lock()
            .unwrap_or_else(|error| panic!("{error}"))
            .hosts
            .clear();
        cx.dispatch_action(RefreshHosts);
        tick(cx);
        assert!(view.read_with(cx, |view, _| view.selected.is_none()));
        cx.dispatch_action(AttachSelected);
        tick(cx);
        assert_eq!(cx.update(|_, app| app.windows().len()), 1);
    }
}
