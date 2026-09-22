//! Real mouse acceptance for a fixture with client-drawn window chrome.
use super::*;
use ::windows::Win32::UI::{HiDpi::GetDpiForWindow, Input::KeyboardAndMouse::*};
use std::{thread::sleep, time::Duration};

pub(super) fn run(host: HWND, child_pid: u32, candidates: &[HWND]) -> Result<(), String> {
    let _dpi = host::DpiScope::enter();
    // SAFETY: host and candidate windows belong exclusively to this fixture tree.
    unsafe {
        let overlay = candidates
            .iter()
            .copied()
            .find(|hwnd| GetWindowLongPtrW(*hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0)
            .ok_or("controlled overlay missing")?;
        let _ = SetForegroundWindow(host);
        geometry::wait_for(|| GetForegroundWindow() == host, 500)
            .map_err(|_| "environment: fixture cannot obtain foreground".to_string())?;
        let margins = crate::OverlayMargins {
            top: 48,
            right: 8,
            bottom: 8,
            left: 8,
        };
        let aligned = || {
            let mut host_rect = RECT::default();
            let mut actual = RECT::default();
            if GetWindowRect(host, &mut host_rect).is_err()
                || GetWindowRect(overlay, &mut actual).is_err()
            {
                return false;
            }
            let expected = margins.inset(
                crate::PhysicalRect {
                    left: host_rect.left,
                    top: host_rect.top,
                    right: host_rect.right,
                    bottom: host_rect.bottom,
                },
                GetDpiForWindow(host),
            );
            IsWindowVisible(overlay).as_bool()
                && (actual.left, actual.top, actual.right, actual.bottom)
                    == (expected.left, expected.top, expected.right, expected.bottom)
        };
        geometry::wait_for(aligned, 500)?;
        let mut before = RECT::default();
        GetWindowRect(host, &mut before).map_err(|e| e.to_string())?;
        let scale = GetDpiForWindow(host) as i32;
        let caption = POINT {
            x: (before.left + before.right) / 2,
            y: before.top + 24 * scale / 96,
        };
        if WindowFromPoint(caption) != host {
            return Err("reserved caption is blocked".into());
        }
        drag(host, child_pid, caption, 64, 32)?;
        geometry::wait_for(
            || {
                let mut after = RECT::default();
                GetWindowRect(host, &mut after).is_ok()
                    && after.left - before.left >= 40
                    && after.top - before.top >= 20
            },
            500,
        )
        .map_err(|_| "client-drawn caption did not move host".to_string())?;
        geometry::wait_for(aligned, 500)?;
        GetWindowRect(host, &mut before).map_err(|e| e.to_string())?;
        let edge = POINT {
            x: before.right - 2 * scale / 96,
            y: (before.top + before.bottom) / 2,
        };
        if WindowFromPoint(edge) != host {
            return Err("reserved resize edge is blocked".into());
        }
        drag(host, child_pid, edge, 48, 0)?;
        geometry::wait_for(
            || {
                let mut after = RECT::default();
                GetWindowRect(host, &mut after).is_ok() && after.right - before.right >= 30
            },
            500,
        )
        .map_err(|_| "client-drawn border did not resize host".to_string())?;
        geometry::wait_for(aligned, 500)?;
        println!("PROBE_MARGINS_OK real_caption_drag=true real_border_resize=true");
    }
    Ok(())
}

fn drag(host: HWND, child_pid: u32, start: POINT, dx: i32, dy: i32) -> Result<(), String> {
    let mouse = |flags| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dwFlags: flags,
                ..Default::default()
            },
        },
    };
    // SAFETY: check target ownership/foreground before pointer changes. Release
    // the button we pressed even if a later guard fails; never leave capture held.
    unsafe {
        if GetForegroundWindow() != host || WindowFromPoint(start) != host {
            return Err("environment: fixture drag target lost foreground or is occluded".into());
        }
        SetCursorPos(start.x, start.y).map_err(|e| e.to_string())?;
        super::fixture::send_owned(host, child_pid, &[mouse(MOUSEEVENTF_LEFTDOWN)], false)?;
        sleep(Duration::from_millis(100));
        let result = (|| {
            let end = POINT {
                x: start.x + dx,
                y: start.y + dy,
            };
            let thread = GetWindowThreadProcessId(host, None);
            let mut info = GUITHREADINFO {
                cbSize: std::mem::size_of::<GUITHREADINFO>() as u32,
                ..Default::default()
            };
            if GetForegroundWindow() != host
                || GetGUIThreadInfo(thread, &mut info).is_err()
                || info.hwndCapture != host
            {
                return Err(
                    "environment: fixture did not retain foreground and drag capture".into(),
                );
            }
            SetCursorPos(end.x, end.y).map_err(|e| e.to_string())?;
            sleep(Duration::from_millis(100));
            Ok(())
        })();
        let released = SendInput(
            &[mouse(MOUSEEVENTF_LEFTUP)],
            std::mem::size_of::<INPUT>() as i32,
        );
        if released != 1 {
            return Err("fixture mouse release failed".into());
        }
        result
    }
}
