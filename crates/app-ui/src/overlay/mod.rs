//! GPUI overlay integration; native interoperability is confined to the bridge.
use gpui_kit::AppContext as _;
mod driver;
mod native_bridge;
mod root;
mod runtime;
mod session;
mod types;
mod window;
pub use native_bridge::{
    ErrorKind, HiddenReason, HostInfo, HostList, HostWindowId, InputMode, OverlayError,
    OverlayMargins, PhysicalRect, PresentationDiagnostics, PresentationRecord, PromotionStatus,
    RawHostHandle,
};
pub use runtime::{init, prepare_quit};
pub use types::*;
pub use window::{OverlayWindow, open_window};

pub fn list_hosts(cx: &gpui_kit::App) -> gpui_kit::Task<Result<HostList, OverlayError>> {
    native_bridge::discover_task(cx)
}
pub fn resolve_host(
    raw: RawHostHandle,
    cx: &gpui_kit::App,
) -> gpui_kit::Task<Result<HostWindowId, OverlayError>> {
    cx.background_spawn(async move { native_bridge::resolve(raw.0) })
}

mod probe;
pub use probe::run_feasibility_probe;
#[cfg(test)]
mod tests;
#[cfg(test)]
pub(crate) use native_bridge::testing;
