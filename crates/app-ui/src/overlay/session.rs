use super::{
    native_bridge::{ErrorKind, InputMode, OverlayError},
    types::*,
};
use gpui_kit::{AnyWindowHandle, Context, EventEmitter, Task};

pub(super) struct Session {
    pub snapshot: OverlaySnapshot,
    pub owner: AnyWindowHandle,
    pub window: Option<AnyWindowHandle>,
    pub desired_mode: InputMode,
    pub mode_revision: u64,
    pub task: Option<Task<()>>,
    pub changed: super::native_bridge::ChangeSignal,
}
impl EventEmitter<OverlayEvent> for Session {}
impl Session {
    pub fn publish(&mut self, kind: OverlayEventKind, cx: &mut Context<Self>) {
        self.snapshot.revision += 1;
        cx.emit(OverlayEvent {
            kind,
            snapshot: self.snapshot.clone(),
        });
        cx.notify();
    }
    pub fn request_close(&mut self, cx: &mut Context<Self>) {
        if matches!(
            self.snapshot.phase,
            OverlayPhase::Closing | OverlayPhase::Closed
        ) {
            return;
        }
        self.snapshot.phase = OverlayPhase::Closing;
        self.changed.notify();
        self.publish(OverlayEventKind::StateChanged, cx);
    }
    pub fn request_mode(
        &mut self,
        mode: InputMode,
        _: &mut Context<Self>,
    ) -> Result<(), OverlayError> {
        if matches!(
            self.snapshot.phase,
            OverlayPhase::Closing | OverlayPhase::Closed
        ) {
            return Err(closed());
        }
        if self.desired_mode != mode {
            self.desired_mode = mode;
            self.mode_revision += 1;
            self.changed.notify();
        }
        Ok(())
    }
}
pub(super) fn closed() -> OverlayError {
    OverlayError {
        kind: ErrorKind::SessionClosed,
        native_code: None,
        message: "Overlay session is closed.".into(),
    }
}
