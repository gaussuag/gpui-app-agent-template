use gpui_kit::{App, Window};
#[cfg(all(windows, feature = "test-support"))]
pub(super) fn dpi_test_target(window: &Window) -> Result<overlay_win32::DpiTestWindow, String> {
    let handle = raw_window_handle::HasWindowHandle::window_handle(window)
        .map_err(|error| error.to_string())?;
    overlay_win32::DpiTestWindow::new(handle).map_err(|error| error.to_string())
}
pub(super) fn resources() -> overlay_win32::ResourceCounts {
    overlay_win32::resource_counts()
}
pub(super) use overlay_win32::ChangeSignal;
pub(super) use overlay_win32::HostSnapshot;
pub use overlay_win32::{
    ErrorKind, HiddenReason, HostInfo, HostList, HostWindowId, InputMode, OverlayError,
    OverlayMargins, PhysicalRect, RawHostHandle,
};

pub(super) fn failure(kind: ErrorKind, message: &str) -> OverlayError {
    OverlayError {
        kind,
        native_code: None,
        message: message.into(),
    }
}
pub(super) fn ensure_supported() -> Result<(), OverlayError> {
    if cfg!(windows) || cfg!(test) {
        Ok(())
    } else {
        Err(failure(
            ErrorKind::UnsupportedPlatform,
            "Native overlays require Windows.",
        ))
    }
}
pub(super) fn resolve(raw: usize) -> Result<HostWindowId, OverlayError> {
    overlay_win32::resolve_host(RawHostHandle(raw))
}
pub(super) fn discover() -> Result<HostList, OverlayError> {
    overlay_win32::list_hosts()
}

pub(super) fn discover_task(cx: &App) -> gpui_kit::Task<Result<HostList, OverlayError>> {
    use gpui_kit::AppContext as _;
    #[cfg(test)]
    if cx.has_global::<testing::Backend>() {
        let backend = cx.global::<testing::Backend>().clone();
        return cx.background_spawn(async move {
            backend
                .hosts
                .lock()
                .map(|hosts| hosts.clone())
                .map_err(|_| failure(ErrorKind::TrackingFailed, "Test discovery unavailable"))
        });
    }
    cx.background_spawn(async { discover() })
}

pub(super) enum WindowBinding {
    Native(overlay_win32::WindowBinding),
    #[cfg(test)]
    Simulated(testing::Backend),
}
impl WindowBinding {
    pub fn presentation_changed(&self) -> bool {
        match self {
            Self::Native(native) => native.presentation_changed(),
            #[cfg(test)]
            Self::Simulated(_) => false,
        }
    }
    pub fn set_change_signal(&self, signal: ChangeSignal) {
        match self {
            Self::Native(native) => native.set_change_signal(signal),
            #[cfg(test)]
            Self::Simulated(_) => {}
        }
    }
    pub fn take_warning(&mut self) -> Option<OverlayError> {
        match self {
            Self::Native(native) => native.take_warning(),
            #[cfg(test)]
            Self::Simulated(_) => None,
        }
    }
    pub fn usable(&self) -> bool {
        match self {
            Self::Native(native) => native.usable(),
            #[cfg(test)]
            Self::Simulated(_) => true,
        }
    }
    pub fn unbind(&mut self) -> Result<(), OverlayError> {
        match self {
            Self::Native(native) => native.unbind().map_err(|error| OverlayError {
                kind: ErrorKind::TrackingFailed,
                native_code: Some(error.code().0),
                message: error.to_string(),
            }),
            #[cfg(test)]
            Self::Simulated(_) => Ok(()),
        }
    }
    pub fn return_focus(&self, host: HostWindowId) -> Result<(), OverlayError> {
        match self {
            Self::Native(native) => native.return_focus(host).map_err(|error| OverlayError {
                kind: ErrorKind::AccessDenied,
                native_code: Some(error.code().0),
                message: "Windows declined focus return; click the host to continue.".into(),
            }),
            #[cfg(test)]
            Self::Simulated(_) => Ok(()),
        }
    }
    pub fn watch_factory(&self) -> WatchFactory {
        match self {
            Self::Native(_) => WatchFactory::Native,
            #[cfg(test)]
            Self::Simulated(backend) => WatchFactory::Simulated(backend.clone()),
        }
    }
    pub fn set_mode(&mut self, mode: InputMode) -> Result<(), OverlayError> {
        match self {
            Self::Native(native) => native.set_mode(mode).map_err(|error| OverlayError {
                kind: ErrorKind::NativeSetupFailed,
                native_code: Some(error.code().0),
                message: error.to_string(),
            }),
            #[cfg(test)]
            Self::Simulated(backend) => backend.set_mode(mode),
        }
    }
    pub fn apply_host(
        &mut self,
        host: HostWindowId,
        sequence: u64,
        margins: OverlayMargins,
    ) -> Result<HostSnapshot, OverlayError> {
        match self {
            Self::Native(native) => {
                native
                    .apply_host(host, sequence, margins)
                    .map_err(|error| OverlayError {
                        kind: ErrorKind::TrackingFailed,
                        native_code: Some(error.code().0),
                        message: error.to_string(),
                    })
            }
            #[cfg(test)]
            Self::Simulated(backend) => {
                let sample = backend.applied(host, sequence).with_margins(margins);
                backend.hidden.store(
                    sample.visibility_reason.is_some(),
                    std::sync::atomic::Ordering::SeqCst,
                );
                Ok(sample)
            }
        }
    }
    pub fn hide(&mut self) {
        match self {
            Self::Native(native) => native.hide(),
            #[cfg(test)]
            Self::Simulated(backend) => backend
                .hidden
                .store(true, std::sync::atomic::Ordering::SeqCst),
        }
    }
}
pub(super) fn bind(window: &Window, _cx: &App) -> Result<WindowBinding, OverlayError> {
    #[cfg(test)]
    if _cx.has_global::<testing::Backend>() {
        let backend = _cx.global::<testing::Backend>().clone();
        backend.check_failure(&backend.fail_bind, ErrorKind::NativeSetupFailed)?;
        return Ok(WindowBinding::Simulated(backend));
    }
    let handle = raw_window_handle::HasWindowHandle::window_handle(window)
        .map_err(|error| failure(ErrorKind::NativeSetupFailed, &error.to_string()))?;
    overlay_win32::WindowBinding::bind(handle)
        .map(WindowBinding::Native)
        .map_err(|error| OverlayError {
            kind: ErrorKind::NativeSetupFailed,
            native_code: Some(error.code().0),
            message: error.to_string(),
        })
}

pub(super) enum WatchFactory {
    Native,
    #[cfg(test)]
    Simulated(testing::Backend),
}
impl WatchFactory {
    pub fn start(self, host: HostWindowId, changed: ChangeSignal) -> Result<Watch, OverlayError> {
        match self {
            Self::Native => overlay_win32::HostWatch::start(host, changed).map(Watch::Native),
            #[cfg(test)]
            Self::Simulated(backend) => {
                backend.check_failure(&backend.fail_start, ErrorKind::TrackingFailed)?;
                if let Ok(mut signal) = backend.changed.lock() {
                    *signal = Some(changed);
                }
                Ok(Watch::Simulated(
                    backend,
                    host,
                    std::sync::atomic::AtomicBool::new(false),
                ))
            }
        }
    }
}
pub(super) enum Watch {
    Native(overlay_win32::HostWatch),
    #[cfg(test)]
    Simulated(
        testing::Backend,
        HostWindowId,
        std::sync::atomic::AtomicBool,
    ),
}
impl Watch {
    pub fn take_latest(&self) -> Result<Option<HostSnapshot>, OverlayError> {
        match self {
            Self::Native(watch) => watch.take_latest(),
            #[cfg(test)]
            Self::Simulated(backend, host, read) => {
                if read.swap(true, std::sync::atomic::Ordering::SeqCst) {
                    Ok(backend.take())
                } else {
                    Ok(Some(backend.sample(*host, 1)))
                }
            }
        }
    }
    pub fn stop(&self) {
        match self {
            Self::Native(watch) => watch.request_stop(),
            #[cfg(test)]
            Self::Simulated(_, _, _) => {}
        }
    }
    pub fn finish(self) -> Result<(), OverlayError> {
        match self {
            Self::Native(watch) => watch.finish(),
            #[cfg(test)]
            Self::Simulated(backend, _, _) => {
                backend.check_failure(&backend.fail_finish, ErrorKind::TrackingFailed)
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    };
    #[derive(Clone, Default)]
    pub struct Backend {
        pub hosts: Arc<Mutex<HostList>>,
        pub fail_mode: Arc<AtomicBool>,
        pub fail_bind: Arc<AtomicBool>,
        pub fail_start: Arc<AtomicBool>,
        pub fail_finish: Arc<AtomicBool>,
        pub hidden: Arc<AtomicBool>,
        pending: Arc<Mutex<Option<HostSnapshot>>>,
        current: Arc<Mutex<Option<HostSnapshot>>>,
        pub(super) changed: Arc<Mutex<Option<ChangeSignal>>>,
    }
    impl gpui_kit::Global for Backend {}
    impl Backend {
        pub fn check_failure(
            &self,
            flag: &AtomicBool,
            kind: ErrorKind,
        ) -> Result<(), OverlayError> {
            if flag.swap(false, Ordering::SeqCst) {
                Err(failure(kind, "Injected native failure"))
            } else {
                Ok(())
            }
        }
        pub fn applied(&self, host: HostWindowId, sequence: u64) -> HostSnapshot {
            self.current
                .lock()
                .ok()
                .and_then(|snapshot| snapshot.clone())
                .filter(|snapshot| {
                    snapshot.generation == host.generation() && snapshot.sequence == sequence
                })
                .unwrap_or_else(|| self.sample(host, sequence))
        }
        pub fn set_mode(&self, _: InputMode) -> Result<(), OverlayError> {
            if self.fail_mode.swap(false, Ordering::SeqCst) {
                Err(failure(
                    ErrorKind::NativeSetupFailed,
                    "Injected mode failure",
                ))
            } else {
                Ok(())
            }
        }
        pub fn sample(&self, host: HostWindowId, sequence: u64) -> HostSnapshot {
            HostSnapshot {
                sampled_at: std::time::Instant::now(),
                generation: host.generation(),
                sequence,
                physical_client_rect: PhysicalRect {
                    left: -700,
                    top: 0,
                    right: -100,
                    bottom: 400,
                },
                physical_overlay_rect: PhysicalRect::default(),
                visibility_reason: None,
                dpi: 144,
                input_suspended: false,
                terminal: None,
            }
        }
        pub fn submit(&self, snapshot: HostSnapshot) {
            if let Ok(mut current) = self.current.lock() {
                *current = Some(snapshot.clone());
            }
            if let Ok(mut pending) = self.pending.lock() {
                *pending = Some(snapshot);
            }
            if let Ok(changed) = self.changed.lock()
                && let Some(changed) = changed.as_ref()
            {
                changed.notify();
            }
        }
        pub fn take(&self) -> Option<HostSnapshot> {
            self.pending
                .lock()
                .ok()
                .and_then(|mut pending| pending.take())
        }
    }
}
