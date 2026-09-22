use super::{
    native_bridge::*,
    runtime::{self, Runtime},
    session::{self, Session},
    types::*,
};
use gpui_kit::{App, AppContext as _, Context, Entity, Render, Subscription, WeakEntity, Window};

/// Cloneable operation handle. Dropping handles does not close the window.
pub struct OverlayWindow<V: Render + 'static> {
    session: Entity<Session>,
    content: WeakEntity<V>,
}
impl<V: Render + 'static> Clone for OverlayWindow<V> {
    fn clone(&self) -> Self {
        Self {
            session: self.session.clone(),
            content: self.content.clone(),
        }
    }
}
impl<V: Render + 'static> OverlayWindow<V> {
    pub fn content(&self, cx: &App) -> Result<Entity<V>, OverlayError> {
        if !runtime::is_open(&self.session.read(cx).snapshot.phase) {
            return Err(session::closed());
        }
        self.content.upgrade().ok_or_else(session::closed)
    }
    pub fn update<R>(
        &self,
        cx: &mut App,
        f: impl FnOnce(&mut V, &mut Window, &mut Context<V>) -> R,
    ) -> Result<R, OverlayError> {
        let content = self.content(cx)?;
        let window = self.session.read(cx).window.ok_or_else(session::closed)?;
        window
            .update(cx, |_, window, cx| {
                content.update(cx, |view, cx| f(view, window, cx))
            })
            .map_err(|_| session::closed())
    }
    pub fn snapshot(&self, cx: &App) -> Result<OverlaySnapshot, OverlayError> {
        Ok(self.session.read(cx).snapshot.clone())
    }
    pub fn observe(
        &self,
        cx: &mut App,
        mut callback: impl FnMut(OverlayEvent, &mut App) + 'static,
    ) -> Subscription {
        let snapshot = self.session.read(cx).snapshot.clone();
        let kind = if snapshot.phase == OverlayPhase::Closed {
            OverlayEventKind::Closed
        } else {
            OverlayEventKind::StateChanged
        };
        callback(OverlayEvent { kind, snapshot }, cx);
        cx.subscribe(&self.session, move |_, event: &OverlayEvent, cx| {
            callback(event.clone(), cx)
        })
    }
    pub fn set_input_mode(&self, mode: InputMode, cx: &mut App) -> Result<(), OverlayError> {
        self.session
            .update(cx, |state, cx| state.request_mode(mode, cx))
    }
    /// Schedule a viewport update without rebuilding the content entity.
    pub fn set_margins(&self, margins: OverlayMargins, cx: &mut App) -> Result<(), OverlayError> {
        self.session.update(cx, |state, _| {
            if !runtime::is_open(&state.snapshot.phase) {
                return Err(session::closed());
            }
            if state.desired_margins != margins {
                state.desired_margins = margins;
                state.changed.notify();
            }
            Ok(())
        })
    }
    pub fn close(&self, cx: &mut App) -> Result<(), OverlayError> {
        self.session.update(cx, |state, cx| state.request_close(cx));
        Ok(())
    }
}

pub fn open_window<V: Render + 'static>(
    host: HostWindowId,
    options: OverlayOptions,
    build: impl FnOnce(&mut Window, &mut App) -> Entity<V> + 'static,
    cx: &mut App,
) -> Result<OverlayWindow<V>, OverlayError> {
    use gpui_kit::{Styled as _, WindowBackgroundAppearance, WindowKind, WindowOptions};
    ensure_supported()?;
    runtime::init(cx);
    if !cx.windows().contains(&options.owner)
        || cx
            .global::<Runtime>()
            .sessions
            .values()
            .any(|session| session.read(cx).window == Some(options.owner))
    {
        return Err(failure(
            ErrorKind::WindowCreateFailed,
            "Owner must be a live ordinary GPUI window.",
        ));
    }
    if cx
        .global::<Runtime>()
        .sessions
        .values()
        .any(|session| session.read(cx).snapshot.host.raw() == host.raw())
    {
        return Err(failure(
            ErrorKind::AlreadyAttached,
            "Host is already attached; wait for detach to finish.",
        ));
    }
    cx.global_mut::<Runtime>().next_id += 1;
    let id = cx.global::<Runtime>().next_id;
    let session = cx.new(|_| Session {
        snapshot: OverlaySnapshot {
            session_id: id,
            revision: 0,
            phase: OverlayPhase::Attaching,
            host,
            input_mode: options.input_mode,
            physical_client_rect: None,
            physical_overlay_rect: None,
            margins: options.margins,
            input_suspended: false,
            hidden_reason: None,
            error: None,
            native_updates: 0,
            presentation: Default::default(),
            sample_to_apply: None,
        },
        owner: options.owner,
        window: None,
        desired_mode: options.input_mode,
        desired_margins: options.margins,
        mode_revision: 0,
        task: None,
        changed: ChangeSignal::default(),
    });
    let mut content = None;
    let opened = cx
        .open_window(
            WindowOptions {
                show: false,
                focus: false,
                kind: WindowKind::PopUp,
                is_movable: false,
                is_resizable: false,
                is_minimizable: false,
                window_background: WindowBackgroundAppearance::Transparent,
                ..Default::default()
            },
            |window, cx| {
                let view = build(window, cx);
                content = Some(view.downgrade());
                let surface = cx.new(|cx| super::root::Surface {
                    content: view,
                    session: session.downgrade(),
                    focus: cx.focus_handle(),
                    escape_had_transient: false,
                });
                if window.focused(cx).is_none() {
                    let focus = surface.read(cx).focus.clone();
                    window.focus(&focus, cx);
                }
                cx.new(|cx| {
                    gpui_kit::component::Root::new(surface, window, cx).bg(gpui_kit::rgba(0))
                })
            },
        )
        .map_err(|error| failure(ErrorKind::WindowCreateFailed, &error.to_string()))?;
    let window: gpui_kit::AnyWindowHandle = opened.into();
    let Some(content) = content else {
        return Err(failure(
            ErrorKind::WindowCreateFailed,
            "Content factory did not run.",
        ));
    };
    session.update(cx, |state, _| state.window = Some(window));
    cx.global_mut::<Runtime>()
        .sessions
        .insert(id, session.clone());
    super::driver::start(&session, cx);
    Ok(OverlayWindow { session, content })
}
