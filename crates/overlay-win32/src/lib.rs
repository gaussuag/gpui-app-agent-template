//! Native overlay adapter. All Windows knowledge lives in `windows`.
mod signal;
pub use signal::ChangeSignal;
#[cfg(not(windows))]
mod unsupported;
#[cfg(windows)]
#[allow(unsafe_code)]
mod windows;
#[cfg(not(windows))]
pub use unsupported::{
    HostWatch, WindowBinding, list_hosts, resolve_host, resource_counts, run_fixture,
};
#[cfg(all(windows, feature = "test-support"))]
pub use windows::DpiTestWindow;

#[cfg(windows)]
pub use windows::{
    HostWatch, WindowBinding, list_hosts, resolve_host, resource_counts, run_fixture,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ResourceCounts {
    pub workers: usize,
    pub hooks: usize,
    pub bindings: usize,
}

/// Overlay input policy, applied only to our own window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputMode {
    Passthrough,
    Interactive,
}

/// Physical screen coordinates. Right/bottom are exclusive.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PhysicalRect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl PhysicalRect {
    pub fn width(self) -> i32 {
        self.right.saturating_sub(self.left)
    }
    pub fn height(self) -> i32 {
        self.bottom.saturating_sub(self.top)
    }
}

/// An untrusted external handle number; must be resolved before attaching.
#[derive(Clone, Copy, Debug)]
pub struct RawHostHandle(pub usize);

/// A validated host identity. A new resolution receives a fresh generation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HostWindowId {
    raw: usize,
    pid: u32,
    tid: u32,
    generation: u64,
}

impl HostWindowId {
    /// Internal adapter-seam fixture, excluded from production builds.
    #[cfg(feature = "test-support")]
    pub fn fixture(generation: u64) -> Self {
        Self {
            raw: generation as usize,
            pid: 1,
            tid: 1,
            generation,
        }
    }
    pub fn raw(self) -> usize {
        self.raw
    }
    pub fn process_id(self) -> u32 {
        self.pid
    }
    pub fn generation(self) -> u64 {
        self.generation
    }
}

#[derive(Clone, Debug)]
pub struct HostInfo {
    pub id: HostWindowId,
    pub title: String,
}

#[derive(Clone, Debug, Default)]
pub struct HostList {
    pub hosts: Vec<HostInfo>,
    pub skipped: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    InvalidHost,
    HostGone,
    UnsupportedHost,
    AccessDenied,
    AlreadyAttached,
    WindowCreateFailed,
    NativeSetupFailed,
    TrackingFailed,
    SessionClosed,
    UnsupportedPlatform,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OverlayError {
    pub kind: ErrorKind,
    pub native_code: Option<i32>,
    pub message: String,
}
impl std::fmt::Display for OverlayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}
impl std::error::Error for OverlayError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HiddenReason {
    Background,
    Minimized,
    Invisible,
    Cloaked,
    EmptyClient,
}

/// Platform facts; the consumer never reconstructs Win32 visibility rules.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostSnapshot {
    pub sampled_at: std::time::Instant,
    pub generation: u64,
    pub sequence: u64,
    pub physical_client_rect: PhysicalRect,
    pub visibility_reason: Option<HiddenReason>,
    pub dpi: u32,
    pub terminal: Option<OverlayError>,
}
