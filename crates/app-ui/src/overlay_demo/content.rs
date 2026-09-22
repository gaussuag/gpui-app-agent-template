use crate::overlay::{InputMode, OverlaySnapshot};
use gpui_kit::component::{
    ActiveTheme as _, WindowExt as _,
    button::{Button, ButtonVariants as _},
    h_flex,
    input::{Input, InputState},
    menu::DropdownMenu as _,
    switch::Switch,
    v_flex,
};
use gpui_kit::{Context, Entity, Render, Window, actions, div, prelude::*, px, rgba};

actions!(
    overlay_content,
    [
        IncrementOverlay,
        ResetOverlay,
        ShowDialog,
        ShowSheet,
        ShowNotification
    ]
);

/// Ordinary business UI, shared unchanged by both window containers.
pub(crate) struct DemoContent {
    focus: gpui_kit::FocusHandle,
    pub(crate) count: usize,
    pub(crate) input: Entity<InputState>,
    enabled: bool,
    pub(crate) corner_markers: bool,
    mode: InputMode,
    snapshot: Option<OverlaySnapshot>,
    updates: u64,
}
impl DemoContent {
    pub(crate) fn new(mode: InputMode, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            focus,
            count: 0,
            input: cx.new(|cx| InputState::new(window, cx).placeholder("输入文字 / Chinese IME")),
            enabled: true,
            corner_markers: false,
            mode,
            snapshot: None,
            updates: 0,
        }
    }
    /// Demo-only diagnostic decoration; ordinary content starts without markers.
    pub(crate) fn with_corner_markers(mut self, enabled: bool) -> Self {
        self.corner_markers = enabled;
        self
    }
    pub(crate) fn set_corner_markers(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.corner_markers = enabled;
        cx.notify();
    }
    pub(crate) fn apply(&mut self, snapshot: OverlaySnapshot, cx: &mut Context<Self>) {
        self.mode = snapshot.input_mode;
        self.snapshot = Some(snapshot);
        self.updates += 1;
        cx.notify();
    }
}
impl Render for DemoContent {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let hud = self.mode == InputMode::Passthrough;
        let geometry = self
            .snapshot
            .as_ref()
            .and_then(|state| state.physical_overlay_rect)
            .map(|rect| {
                format!(
                    "Overlay 区域 {} × {} px · ({}, {})",
                    rect.width(),
                    rect.height(),
                    rect.left,
                    rect.top
                )
            })
            .unwrap_or_else(|| "普通窗口内容预览".into());
        let timing = self
            .snapshot
            .as_ref()
            .map(|state| {
                format!(
                    "原生几何/显隐更新 {} 次 · 采样→应用 {:.1} ms",
                    state.native_updates,
                    state.sample_to_apply.unwrap_or_default().as_secs_f64() * 1000.
                )
            })
            .unwrap_or_else(|| "原生同步指标仅在附着会话中测量".into());
        let panel = v_flex()
            .gap_3()
            .p_4()
            .w(px(380.))
            .max_w_full()
            .rounded_lg()
            .bg(cx.theme().background.opacity(0.96))
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .text_lg()
                    .child(if hud { "Overlay HUD" } else { "交互 Overlay" }),
            )
            .child(div().text_sm().child(geometry))
            .child(div().text_xs().child(timing))
            .child(
                div()
                    .text_xs()
                    .child(format!("状态通知 {} 次 · 非宿主 FPS", self.updates)),
            )
            .when(!hud, |panel| {
                panel
                    .child(
                        h_flex()
                            .gap_2()
                            .child(
                                Button::new("overlay-count")
                                    .primary()
                                    .label(format!("计数 {}", self.count))
                                    .tooltip("普通 GPUI Action；切换模式后计数保留")
                                    .on_click(|_, window, cx| {
                                        window.dispatch_action(Box::new(IncrementOverlay), cx)
                                    }),
                            )
                            .child(Button::new("overlay-menu").label("菜单").dropdown_menu(
                                |menu, _, _| {
                                    menu.menu("重置计数", Box::new(ResetOverlay))
                                        .menu("提示", Box::new(ShowNotification))
                                },
                            )),
                    )
                    .child(
                        Switch::new("overlay-switch")
                            .label("保留开关状态")
                            .checked(self.enabled)
                            .on_click(cx.listener(|view, checked, _, cx| {
                                view.enabled = *checked;
                                cx.notify();
                            })),
                    )
                    .child(Input::new(&self.input).id("overlay-input"))
                    .child(
                        h_flex()
                            .gap_2()
                            .child(Button::new("overlay-dialog").label("Dialog").on_click(
                                |_, window, cx| window.dispatch_action(Box::new(ShowDialog), cx),
                            ))
                            .child(Button::new("overlay-sheet").label("Sheet").on_click(
                                |_, window, cx| window.dispatch_action(Box::new(ShowSheet), cx),
                            ))
                            .child(Button::new("overlay-note").label("通知").on_click(
                                |_, window, cx| {
                                    window.dispatch_action(Box::new(ShowNotification), cx)
                                },
                            )),
                    )
                    .child(
                        v_flex()
                            .id("overlay-scroll")
                            .h(px(110.))
                            .overflow_y_scroll()
                            .gap_2()
                            .children((1..=30).map(|index| {
                                div().text_sm().child(format!("可滚动项目 {index:02}"))
                            })),
                    )
                    .child(
                        div()
                            .text_xs()
                            .child("Esc 先关闭菜单/弹层或结束输入法组合，再切回 HUD。"),
                    )
            });
        let corner = || {
            div()
                .absolute()
                .size(px(16.))
                .border_2()
                .border_color(rgba(0x58e6baff))
        };
        div()
            .track_focus(&self.focus)
            .size_full()
            .overflow_hidden()
            .relative()
            .on_action(cx.listener(|view, _: &IncrementOverlay, _, cx| {
                view.count += 1;
                cx.notify();
            }))
            .on_action(cx.listener(|view, _: &ResetOverlay, _, cx| {
                view.count = 0;
                cx.notify();
            }))
            .on_action(|_: &ShowDialog, window, cx| {
                window.open_dialog(cx, |dialog, _, _| {
                    dialog
                        .title("普通 Kit Dialog")
                        .child("内容没有平台或 overlay 兼容分支。")
                })
            })
            .on_action(|_: &ShowSheet, window, cx| {
                window.open_sheet(cx, |sheet, _, _| sheet.child("普通 Kit Sheet"))
            })
            .on_action(|_: &ShowNotification, window, cx| {
                window.push_notification("普通 Kit 通知", cx)
            })
            .when(self.corner_markers, |view| {
                view.child(corner().top_0().left_0())
                    .child(corner().top_0().right_0())
                    .child(corner().bottom_0().left_0())
                    .child(corner().bottom_0().right_0())
            })
            .child(div().p_5().size_full().overflow_hidden().child(panel))
    }
}
