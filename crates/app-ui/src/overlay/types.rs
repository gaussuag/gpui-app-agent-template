use super::native_bridge::{HiddenReason, HostWindowId, InputMode, OverlayError, PhysicalRect};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OverlayPhase {
    Attaching,
    Attached,
    Closing,
    Closed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OverlaySnapshot {
    pub session_id: u64,
    pub revision: u64,
    pub phase: OverlayPhase,
    pub host: HostWindowId,
    pub input_mode: InputMode,
    pub physical_client_rect: Option<PhysicalRect>,
    pub hidden_reason: Option<HiddenReason>,
    pub error: Option<OverlayError>,
    /// Number of committed geometry/visibility changes, including initial state.
    pub native_updates: u64,
    /// Native sample creation to completion of its foreground apply transaction.
    pub sample_to_apply: Option<std::time::Duration>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OverlayEventKind {
    Ready,
    StateChanged,
    ModeChanged,
    OperationFailed,
    Closed,
}

#[derive(Clone, Debug)]
pub struct OverlayEvent {
    pub kind: OverlayEventKind,
    pub snapshot: OverlaySnapshot,
}

pub struct OverlayOptions {
    pub owner: gpui_kit::AnyWindowHandle,
    pub input_mode: InputMode,
}
