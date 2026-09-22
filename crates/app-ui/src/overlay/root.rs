use gpui_kit::component::{Root, WindowExt as _};
use gpui_kit::{Context, Entity, Render, Window, div, prelude::*};

pub(super) struct Surface<V: Render + 'static> {
    pub content: Entity<V>,
    pub session: gpui_kit::WeakEntity<super::session::Session>,
    pub focus: gpui_kit::FocusHandle,
    pub escape_was_composing: bool,
}
impl<V: Render + 'static> Render for Surface<V> {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let sheet = Root::render_sheet_layer(window, cx);
        let dialog = Root::render_dialog_layer(window, cx);
        let notification = Root::render_notification_layer(window, cx);
        div()
            .key_context("OverlaySurface")
            .track_focus(&self.focus)
            .capture_action(cx.listener(
                |surface, _: &gpui_kit::component::input::Escape, window, cx| {
                    surface.escape_was_composing = focused_composition(window, cx, false);
                },
            ))
            .on_action(
                cx.listener(|surface, _: &gpui_kit::component::input::Escape, _, cx| {
                    if std::mem::take(&mut surface.escape_was_composing) {
                        return;
                    }
                    let _ = surface.session.update(cx, |session, cx| {
                        session.request_mode(super::InputMode::Passthrough, cx)
                    });
                }),
            )
            .capture_action(cx.listener(
                |surface, _: &gpui_kit::component::dialog::Cancel, window, cx| {
                    surface.escape_was_composing = focused_composition(window, cx, false);
                },
            ))
            .on_action(
                cx.listener(|surface, _: &gpui_kit::component::dialog::Cancel, _, cx| {
                    if std::mem::take(&mut surface.escape_was_composing) {
                        return;
                    }
                    let _ = surface.session.update(cx, |session, cx| {
                        session.request_mode(super::InputMode::Passthrough, cx)
                    });
                }),
            )
            .size_full()
            .child(self.content.clone())
            .children(sheet)
            .children(dialog)
            .children(notification)
    }
}

/// Query/finish composition through Kit's normal registered input states. A
/// capture-phase query remembers whether this Escape was consumed by IME even
/// when the input's Cancel handler unmarks text and propagates the Action.
fn focused_composition(window: &mut Window, cx: &mut gpui_kit::App, finish: bool) -> bool {
    use gpui_kit::component::input::AnyInputState;
    fn inspect<T: gpui_kit::EntityInputHandler>(
        entity: Entity<T>,
        window: &mut Window,
        cx: &mut gpui_kit::App,
        finish: bool,
    ) -> bool {
        entity.update(cx, |input, cx| {
            let composing = input.marked_text_range(window, cx).is_some();
            if composing && finish {
                input.unmark_text(window, cx);
            }
            composing
        })
    }
    match window.focused_input(cx) {
        Some(AnyInputState::Input(input)) => inspect(input, window, cx, finish),
        Some(AnyInputState::Textarea(input)) => inspect(input, window, cx, finish),
        Some(AnyInputState::Editor(input)) => inspect(input, window, cx, finish),
        // Kit OTP uses its own key engine, not an EntityInputHandler.
        Some(AnyInputState::Otp(_)) | None => false,
    }
}

pub(super) fn suspend(
    window: &mut Window,
    cx: &mut gpui_kit::App,
) -> Option<gpui_kit::FocusHandle> {
    focused_composition(window, cx, true);
    // Kit menu/popover element state survives a blur. Dispatch its normal
    // Cancel synchronously on the focused popup before saving restored focus.
    // Restrict this to popup contexts so suspension never runs business Cancel.
    if window
        .context_stack()
        .iter()
        .any(|context| context.contains("PopupMenu") || context.contains("Popover"))
        && let Some(focus) = window.focused(cx)
    {
        focus.dispatch_action(&gpui_kit::component::dialog::Cancel, window, cx);
    }
    let focus = window.focused(cx);
    window.close_all_dialogs(cx);
    window.close_sheet(cx);
    window.clear_notifications(cx);
    cx.stop_active_drag(window);
    window.release_pointer();
    window.blur(cx);
    focus
}
