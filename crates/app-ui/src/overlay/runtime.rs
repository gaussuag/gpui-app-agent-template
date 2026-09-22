use super::{session::Session, types::*};
type QuitCompletion = Box<dyn FnOnce(&mut App)>;
use gpui_kit::{App, Entity, Global, Subscription};
use std::collections::HashMap;

#[derive(Default)]
pub(super) struct Runtime {
    pub sessions: HashMap<u64, Entity<Session>>,
    pub next_id: u64,
    observer: Option<Subscription>,
    quit: Vec<QuitCompletion>,
}
impl Global for Runtime {}

pub fn init(cx: &mut App) {
    if cx.has_global::<Runtime>() {
        return;
    }
    // Windows GPUI defaults to quitting as soon as its last window disappears.
    // Keep the foreground executor alive until native cleanup tickets finish.
    cx.set_quit_mode(gpui_kit::QuitMode::Explicit);
    cx.bind_keys([gpui_kit::KeyBinding::new(
        "escape",
        gpui_kit::component::dialog::Cancel,
        Some("OverlaySurface"),
    )]);
    cx.set_global(Runtime::default());
    let observer = cx.on_window_closed(|cx, _| {
        let windows = cx.windows();
        let sessions: Vec<_> = cx.global::<Runtime>().sessions.values().cloned().collect();
        for session in sessions {
            let state = session.read(cx);
            if !windows.contains(&state.owner)
                || state
                    .window
                    .is_some_and(|window| !windows.contains(&window))
            {
                session.update(cx, |state, cx| state.request_close(cx));
            }
        }
    });
    cx.global_mut::<Runtime>().observer = Some(observer);
}

/// Finish all native cleanup before the application performs its final quit.
pub fn prepare_quit(cx: &mut App, done: impl FnOnce(&mut App) + 'static) {
    init(cx);
    let sessions: Vec<_> = cx.global::<Runtime>().sessions.values().cloned().collect();
    if sessions.is_empty() {
        done(cx);
        return;
    }
    cx.global_mut::<Runtime>().quit.push(Box::new(done));
    for session in sessions {
        session.update(cx, |session, cx| session.request_close(cx));
    }
}

pub(super) fn finished(id: u64, cx: &mut App) {
    cx.global_mut::<Runtime>().sessions.remove(&id);
    if cx.global::<Runtime>().sessions.is_empty() {
        let callbacks = std::mem::take(&mut cx.global_mut::<Runtime>().quit);
        for callback in callbacks {
            callback(cx);
        }
    }
}

pub(super) fn is_open(phase: &OverlayPhase) -> bool {
    !matches!(phase, OverlayPhase::Closing | OverlayPhase::Closed)
}
