use crate::*;
use ::windows::Win32::{
    Foundation::*,
    Graphics::{Dwm::*, Gdi::ClientToScreen},
    System::Threading::GetCurrentProcessId,
    UI::{HiDpi::*, WindowsAndMessaging::*},
};
use ::windows::core::BOOL;
use std::sync::atomic::{AtomicU64, Ordering};

static GENERATION: AtomicU64 = AtomicU64::new(1);

pub(super) fn error(kind: ErrorKind, message: &str) -> OverlayError {
    OverlayError {
        kind,
        native_code: None,
        message: message.into(),
    }
}

pub(super) struct DpiScope(DPI_AWARENESS_CONTEXT);
impl DpiScope {
    pub fn enter() -> Self {
        // SAFETY: temporary thread-local DPI override, restored by Drop on this thread.
        Self(unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) })
    }
}
impl Drop for DpiScope {
    fn drop(&mut self) {
        // SAFETY: restore the previous context on the same non-awaiting call stack.
        unsafe {
            let _ = SetThreadDpiAwarenessContext(self.0);
        }
    }
}

pub fn resolve_host(raw: RawHostHandle) -> Result<HostWindowId, OverlayError> {
    let _dpi = DpiScope::enter();
    let hwnd = HWND(raw.0 as *mut _);
    // SAFETY: untrusted numeric handles are only passed to validating OS queries.
    // No memory is dereferenced and the external window is never modified.
    unsafe {
        if raw.0 == 0 || !IsWindow(Some(hwnd)).as_bool() {
            return Err(error(
                ErrorKind::InvalidHost,
                "Window handle is invalid; refresh the list.",
            ));
        }
        let mut pid = 0;
        let tid = GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if tid == 0 {
            return Err(error(ErrorKind::HostGone, "Host closed during resolution."));
        }
        if pid == GetCurrentProcessId()
            || GetAncestor(hwnd, GA_ROOT) != hwnd
            || hwnd == GetDesktopWindow()
            || hwnd == GetShellWindow()
            || GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0
        {
            return Err(error(
                ErrorKind::UnsupportedHost,
                "Select an external top-level application window.",
            ));
        }
        Ok(HostWindowId {
            raw: raw.0,
            pid,
            tid,
            generation: GENERATION.fetch_add(1, Ordering::Relaxed),
        })
    }
}

pub fn list_hosts() -> Result<HostList, OverlayError> {
    let _dpi = DpiScope::enter();
    let mut list = HostList::default();
    // SAFETY: EnumWindows invokes the callback synchronously on this thread;
    // the stack-owned list outlives all callback invocations.
    unsafe {
        EnumWindows(
            Some(enumerate),
            LPARAM((&mut list as *mut HostList) as isize),
        )
    }
    .map_err(|native| OverlayError {
        kind: ErrorKind::AccessDenied,
        native_code: Some(native.code().0),
        message: native.to_string(),
    })?;
    Ok(list)
}

unsafe extern "system" fn enumerate(hwnd: HWND, data: LPARAM) -> BOOL {
    // SAFETY: data is the unique HostList borrowed by synchronous EnumWindows.
    unsafe {
        let list = &mut *(data.0 as *mut HostList);
        let Ok(id) = resolve_host(RawHostHandle(hwnd.0 as usize)) else {
            list.skipped += 1;
            return TRUE;
        };
        if !IsWindowVisible(hwnd).as_bool() || cloaked(hwnd) {
            list.skipped += 1;
            return TRUE;
        }
        // GetWindowText for an external top-level caption does not synchronously
        // call the target's window procedure; bounded buffer limits materialization.
        let mut title = [0u16; 1024];
        let length = GetWindowTextW(hwnd, &mut title).max(0) as usize;
        list.hosts.push(HostInfo {
            id,
            title: String::from_utf16_lossy(&title[..length]),
        });
        TRUE
    }
}

pub(super) fn cloaked(hwnd: HWND) -> bool {
    let mut value = 0u32;
    // SAFETY: fixed-size stack output exactly matches DWMWA_CLOAKED.
    unsafe {
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, (&mut value as *mut u32).cast(), 4).is_ok()
            && value != 0
    }
}

pub(super) fn foreground_matches(id: HostWindowId, overlay: HWND) -> bool {
    // SAFETY: read-only foreground query; identity was sampled by the caller.
    foreground_in_group(
        unsafe { GetForegroundWindow() },
        HWND(id.raw() as *mut _),
        overlay,
    )
}

pub(super) fn foreground_in_group(foreground: HWND, host: HWND, overlay: HWND) -> bool {
    // SAFETY: read-only queries, called after host identity validation on the
    // overlay thread. Native ownership is observed, never created or modified.
    unsafe {
        if foreground.is_invalid() {
            return false;
        }
        let mut current = foreground;
        for _ in 0..64 {
            if current == host || current == overlay {
                return true;
            }
            let Ok(owner) = GetWindow(current, GW_OWNER) else {
                break;
            };
            if owner.is_invalid() {
                break;
            }
            current = owner;
        }
        // Preserve the existing input-method exception without treating every
        // GPUI window on this thread (e.g. the Demo controller) as foreground.
        let thread = GetWindowThreadProcessId(overlay, None);
        if thread == 0 || GetWindowThreadProcessId(foreground, None) != thread {
            return false;
        }
        let mut class = [0u16; 128];
        let len = GetClassNameW(foreground, &mut class).max(0) as usize;
        class[..len].iter().copied().eq("IME".encode_utf16())
            || class[..len]
                .iter()
                .copied()
                .eq("MSCTFIME UI".encode_utf16())
    }
}

pub(super) fn sample(id: HostWindowId, _overlay: Option<HWND>, sequence: u64) -> HostSnapshot {
    let _dpi = DpiScope::enter();
    let hwnd = HWND(id.raw as *mut _);
    let mut snapshot = HostSnapshot {
        sampled_at: std::time::Instant::now(),
        generation: id.generation,
        sequence,
        physical_client_rect: PhysicalRect::default(),
        physical_overlay_rect: PhysicalRect::default(),
        visibility_reason: None,
        dpi: 96,
        input_suspended: false,
        terminal: None,
    };
    // SAFETY: read-only window queries; PID/TID are revalidated on every sample.
    unsafe {
        let mut pid = 0;
        let tid = GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid != id.pid || tid != id.tid || !IsWindow(Some(hwnd)).as_bool() {
            snapshot.terminal = Some(error(
                ErrorKind::HostGone,
                "Host identity is no longer valid.",
            ));
            return snapshot;
        }
        let mut rect = RECT::default();
        let mut first = POINT::default();
        if let Err(native) = GetClientRect(hwnd, &mut rect) {
            snapshot.terminal = Some(OverlayError {
                kind: ErrorKind::TrackingFailed,
                native_code: Some(native.code().0),
                message: "Could not sample host client area.".into(),
            });
            return snapshot;
        }
        let mut last = POINT {
            x: rect.right,
            y: rect.bottom,
        };
        if !ClientToScreen(hwnd, &mut first).as_bool() || !ClientToScreen(hwnd, &mut last).as_bool()
        {
            snapshot.terminal = Some(OverlayError {
                kind: ErrorKind::TrackingFailed,
                native_code: Some(GetLastError().0 as i32),
                message: "Could not map host client coordinates.".into(),
            });
            return snapshot;
        }
        snapshot.physical_client_rect = PhysicalRect {
            left: first.x,
            top: first.y,
            right: last.x,
            bottom: last.y,
        };
        snapshot.physical_overlay_rect = snapshot.physical_client_rect;
        snapshot.dpi = GetDpiForWindow(hwnd);
        snapshot.input_suspended =
            !::windows::Win32::UI::Input::KeyboardAndMouse::IsWindowEnabled(hwnd).as_bool();
        snapshot.visibility_reason = if IsIconic(hwnd).as_bool() {
            Some(HiddenReason::Minimized)
        } else if !IsWindowVisible(hwnd).as_bool() {
            Some(HiddenReason::Invisible)
        } else if cloaked(hwnd) {
            Some(HiddenReason::Cloaked)
        } else if snapshot.physical_client_rect.width() <= 0
            || snapshot.physical_client_rect.height() <= 0
        {
            Some(HiddenReason::EmptyClient)
        } else {
            None
        };
    }
    snapshot
}
