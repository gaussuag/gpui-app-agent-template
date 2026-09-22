//! Explicit unsupported-platform boundary, never a simulated production backend.
use crate::*;
pub fn resource_counts() -> ResourceCounts {
    ResourceCounts::default()
}
fn unsupported() -> OverlayError {
    OverlayError {
        kind: ErrorKind::UnsupportedPlatform,
        native_code: None,
        message: "Native overlays require Windows.".into(),
    }
}
pub fn list_hosts() -> Result<HostList, OverlayError> {
    Err(unsupported())
}
pub fn resolve_host(_: RawHostHandle) -> Result<HostWindowId, OverlayError> {
    Err(unsupported())
}
pub fn run_fixture() -> Result<(), OverlayError> {
    Err(unsupported())
}

#[derive(Debug)]
pub struct NativeError;
pub struct NativeCode(pub i32);
impl NativeError {
    pub fn code(&self) -> NativeCode {
        NativeCode(-1)
    }
}
impl std::fmt::Display for NativeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Native overlays require Windows.")
    }
}
impl std::error::Error for NativeError {}

pub struct WindowBinding(std::marker::PhantomData<std::rc::Rc<()>>);
impl WindowBinding {
    pub fn usable(&self) -> bool {
        false
    }
    pub fn unbind(&mut self) -> Result<(), NativeError> {
        Err(NativeError)
    }
    pub fn bind(_: raw_window_handle::WindowHandle<'_>) -> Result<Self, NativeError> {
        Err(NativeError)
    }
    pub fn set_mode(&mut self, _: InputMode) -> Result<(), NativeError> {
        Err(NativeError)
    }
    pub fn apply_host(
        &mut self,
        _: HostWindowId,
        _: u64,
        _: OverlayMargins,
    ) -> Result<HostSnapshot, NativeError> {
        Err(NativeError)
    }
    pub fn return_focus(&self, _: HostWindowId) -> Result<(), NativeError> {
        Err(NativeError)
    }
    pub fn hide(&mut self) {}
}
pub struct HostWatch;
impl HostWatch {
    pub fn start(_: HostWindowId, _: ChangeSignal) -> Result<Self, OverlayError> {
        Err(unsupported())
    }
    pub fn take_latest(&self) -> Result<Option<HostSnapshot>, OverlayError> {
        Err(unsupported())
    }
    pub fn request_stop(&self) {}
    pub fn finish(self) -> Result<(), OverlayError> {
        Err(unsupported())
    }
}
