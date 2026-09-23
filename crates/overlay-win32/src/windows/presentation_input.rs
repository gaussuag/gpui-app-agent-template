//! A third controlled window for the real first-click regression.
use super::*;
use ::windows::{
    Win32::{
        Graphics::Gdi::ClientToScreen, System::LibraryLoader::GetModuleHandleW,
        UI::HiDpi::GetDpiForWindow,
    },
    core::w,
};
use std::{
    sync::atomic::AtomicUsize,
    time::{Duration, Instant},
};
pub(super) const CREATE_OCCLUDER: u32 = WM_APP + 77;
static OCCLUDER: AtomicUsize = AtomicUsize::new(0);

// SAFETY: static fixture callback; closes only its own window and does not quit
// the host's message pump, which owns both fixture windows.
unsafe extern "system" fn procedure(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        if msg == WM_CLOSE {
            let _ = DestroyWindow(hwnd);
            return LRESULT(0);
        }
        DefWindowProcW(hwnd, msg, wp, lp)
    }
}

pub(super) fn create(host: HWND) -> Result<HWND, Error> {
    // SAFETY: invoked by our fixture host's WndProc on its own UI thread.
    unsafe {
        let instance = GetModuleHandleW(None)?;
        let class = w!("OverlayControlledOccluder");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: instance.into(),
            lpszClassName: class,
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS {
            return Err(Error::from_win32());
        }
        let scale = GetDpiForWindow(host) as f64 / 96.;
        let mut point = POINT {
            x: (400. * scale) as i32,
            y: (100. * scale) as i32,
        };
        if !ClientToScreen(host, &mut point).as_bool() {
            return Err(Error::from_win32());
        }
        CreateWindowExW(
            WS_EX_TOOLWINDOW,
            class,
            w!("Controlled third window"),
            WS_POPUP | WS_VISIBLE,
            point.x,
            point.y,
            (220. * scale) as i32,
            (250. * scale) as i32,
            None,
            None,
            Some(instance.into()),
            None,
        )
    }
}

pub(super) fn is_foreground(hwnd: HWND) -> bool {
    let raw = OCCLUDER.load(Ordering::SeqCst);
    raw != 0 && raw == hwnd.0 as usize
}

pub(super) struct Occluder {
    hwnd: HWND,
    overlay: HWND,
    host: HWND,
}
impl Drop for Occluder {
    fn drop(&mut self) {
        OCCLUDER.store(0, Ordering::SeqCst);
        // SAFETY: HWND was created by our host; request destruction on its thread.
        unsafe {
            let _ = PostMessageW(Some(self.hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }
}
impl Occluder {
    pub fn start(host: HWND, overlay: HWND) -> Result<Self, String> {
        // SAFETY: synchronous fixture-only command, never a user/production host.
        unsafe {
            let raw = SendMessageW(host, CREATE_OCCLUDER, None, None).0;
            if raw == 0 {
                return Err("fixture occluder creation failed".into());
            }
            let this = Self {
                hwnd: HWND(raw as *mut _),
                overlay,
                host,
            };
            OCCLUDER.store(raw as usize, Ordering::SeqCst);
            let _ = SetForegroundWindow(this.hwnd);
            std::thread::sleep(Duration::from_millis(350));
            if GetForegroundWindow() != this.hwnd {
                return Err("environment: controlled occluder could not obtain foreground".into());
            }
            if !IsWindowVisible(overlay).as_bool()
                || !above(this.hwnd, overlay)
                || !above(overlay, host)
            {
                return Err("inactive overlay did not remain visible beneath the occluder and above its host".into());
            }
            println!("PROBE_PRESENTATION_OCCLUSION_OK");
            Ok(this)
        }
    }
    pub fn verify_promoted(&self) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_millis(500);
        loop {
            // SAFETY: read-only observations of our three fixture windows.
            unsafe {
                if GetForegroundWindow() == self.overlay
                    && above(self.overlay, self.host)
                    && above(self.host, self.hwnd)
                {
                    println!("PROBE_PRESENTATION_FIRST_CLICK_OK");
                    return Ok(());
                }
            }
            if Instant::now() >= deadline {
                return Err(
                    "clicked overlay did not promote host while retaining foreground".into(),
                );
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn above(mut first: HWND, second: HWND) -> bool {
    // SAFETY: read-only bounded order traversal; never manipulates neighbors.
    unsafe {
        for _ in 0..64 {
            let Ok(next) = GetWindow(first, GW_HWNDNEXT) else {
                return false;
            };
            if next == second {
                return true;
            }
            first = next;
        }
    }
    false
}

pub(super) fn verify_caption(
    host: HWND,
    overlay: HWND,
    child_pid: u32,
    interactive: bool,
) -> Result<(), String> {
    use ::windows::Win32::UI::Input::KeyboardAndMouse::*;
    // SAFETY: only fixture-owned windows are activated. The caption hit and
    // foreground are checked before each real input batch.
    unsafe {
        let expected = if interactive { overlay } else { host };
        let _ = SetForegroundWindow(expected);
        std::thread::sleep(Duration::from_millis(150));
        if GetForegroundWindow() != expected {
            return Err("environment: controlled caption setup could not obtain foreground".into());
        }
        let mut outer = RECT::default();
        GetWindowRect(host, &mut outer).map_err(|e| e.to_string())?;
        let mut client = POINT::default();
        if !ClientToScreen(host, &mut client).as_bool() {
            return Err("fixture caption mapping failed".into());
        }
        let point = POINT {
            x: (outer.left + outer.right) / 2,
            y: (outer.top + client.y) / 2,
        };
        if WindowFromPoint(point) != host {
            return Err("environment: controlled caption is occluded".into());
        }
        SetCursorPos(point.x, point.y).map_err(|e| e.to_string())?;
        let input = [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP].map(|flags| INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dwFlags: flags,
                    ..Default::default()
                },
            },
        });
        super::fixture::send_owned(host, child_pid, &input, interactive)?;
        std::thread::sleep(Duration::from_millis(500));
        let visible = IsWindowVisible(overlay).as_bool();
        let ordered = above(overlay, host);
        let foreground = GetForegroundWindow();
        let same_band = (GetWindowLongPtrW(host, GWL_EXSTYLE)
            ^ GetWindowLongPtrW(overlay, GWL_EXSTYLE)) as u32
            & WS_EX_TOPMOST.0
            == 0;
        println!(
            "PROBE_CAPTION_STATE interactive={interactive} visible={visible} above_host={ordered} same_band={same_band} foreground={foreground:?} host={host:?}"
        );
        if foreground != host || !visible || !ordered || !same_band {
            return Err("caption click did not retain visible overlay above active host".into());
        }
        println!("PROBE_PRESENTATION_CAPTION_OK");
        Ok(())
    }
}
