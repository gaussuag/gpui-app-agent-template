//! Controlled native geometry/visibility acceptance; never targets user windows.
use ::windows::{
    Win32::{
        Foundation::*,
        Graphics::{Dwm::*, Gdi::*},
        UI::{HiDpi::GetDpiForWindow, Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
    },
    core::{BOOL, w},
};
use std::time::{Duration, Instant};

fn client(host: HWND) -> Result<RECT, String> {
    // SAFETY: only read the fixture-owned window's physical client rectangle.
    unsafe {
        let mut rect = RECT::default();
        GetClientRect(host, &mut rect).map_err(|error| error.to_string())?;
        let mut origin = POINT::default();
        if !ClientToScreen(host, &mut origin).as_bool() {
            return Err("client mapping failed".into());
        }
        Ok(RECT {
            left: origin.x,
            top: origin.y,
            right: origin.x + rect.right,
            bottom: origin.y + rect.bottom,
        })
    }
}

pub(super) fn wait_for(
    mut matches: impl FnMut() -> bool,
    limit_ms: u64,
) -> Result<Duration, String> {
    let started = Instant::now();
    loop {
        let matched = matches();
        let elapsed = started.elapsed();
        if elapsed > Duration::from_millis(limit_ms) {
            return Err(format!(
                "native state did not converge within {limit_ms} ms"
            ));
        }
        if matched {
            return Ok(elapsed);
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

pub(super) fn aligned(host: HWND, overlay: HWND) -> bool {
    let Ok(expected) = client(host) else {
        return false;
    };
    let mut actual = RECT::default();
    // SAFETY: read-only queries of our fixture and its owned child process.
    unsafe {
        IsWindowVisible(overlay).as_bool()
            && GetWindowRect(overlay, &mut actual).is_ok()
            && [
                actual.left - expected.left,
                actual.top - expected.top,
                actual.right - expected.right,
                actual.bottom - expected.bottom,
            ]
            .into_iter()
            .all(|delta| delta.abs() <= 1)
    }
}

pub(super) fn run(host: HWND, candidates: &[HWND]) -> Result<(), String> {
    let _dpi = super::host::DpiScope::enter();
    // SAFETY: the caller obtained candidates by filtering EnumWindows to the
    // process it created. Only the fixture host/popup is moved or activated.
    unsafe {
        let _ = SetForegroundWindow(host);
        wait_for(|| GetForegroundWindow() == host, 500)
            .map_err(|_| "environment: fixture could not obtain foreground".to_string())?;
        let overlay = candidates
            .iter()
            .copied()
            .find(|window| GetWindowLongPtrW(*window, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0)
            .ok_or("controlled overlay not found")?;
        wait_for(|| aligned(host, overlay), 500)?;
        let mut initial = RECT::default();
        GetWindowRect(host, &mut initial).map_err(|error| error.to_string())?;
        let mut samples = Vec::new();
        for index in 1..=32 {
            if GetForegroundWindow() != host {
                return Err("environment: foreground changed during geometry measurement".into());
            }
            let started = Instant::now();
            SetWindowPos(
                host,
                None,
                initial.left + index * 3,
                initial.top + index * 2,
                initial.right - initial.left - index % 5 * 12,
                initial.bottom - initial.top - index % 3 * 12,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )
            .map_err(|error| error.to_string())?;
            wait_for(|| aligned(host, overlay), 100)?;
            let elapsed = started.elapsed();
            if elapsed > Duration::from_millis(100) {
                return Err("geometry trigger-to-observed-apply exceeded 100 ms".into());
            }
            samples.push(elapsed);
            std::thread::sleep(Duration::from_millis(17));
        }
        samples.sort();
        let p95 = samples[30];
        println!(
            "OVERLAY_GEOMETRY samples=32 dpi={} p95_ms={:.3} max_ms={:.3} edge_error_px<=1",
            GetDpiForWindow(host),
            p95.as_secs_f64() * 1000.,
            samples[31].as_secs_f64() * 1000.
        );
        if p95 > Duration::from_millis(50) {
            return Err("geometry trigger-to-observed-apply P95 exceeded 50 ms".into());
        }
        for command in [SW_MAXIMIZE, SW_RESTORE] {
            let _ = ShowWindow(host, command);
            wait_for(|| aligned(host, overlay), 100)?;
        }
        for command in [SW_MINIMIZE, SW_HIDE] {
            let _ = ShowWindow(host, command);
            let latency = wait_for(|| !IsWindowVisible(overlay).as_bool(), 100)?;
            println!(
                "OVERLAY_HIDE command={} latency_ms={:.3}",
                command.0,
                latency.as_secs_f64() * 1000.
            );
            let _ = ShowWindow(host, SW_RESTORE);
            let _ = SetForegroundWindow(host);
            wait_for(|| aligned(host, overlay), 100)?;
        }
        // An owned popup is deliberately not the host root and must hide it.
        let popup = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("STATIC"),
            w!("Controlled host popup"),
            WS_POPUP | WS_VISIBLE,
            initial.left + 100,
            initial.top + 100,
            240,
            120,
            Some(host),
            None,
            None,
            None,
        )
        .map_err(|error| error.to_string())?;
        let _ = SetForegroundWindow(popup);
        let popup_check = wait_for(
            || GetForegroundWindow() == popup && !IsWindowVisible(overlay).as_bool(),
            100,
        );
        let _ = DestroyWindow(popup);
        let _ = SetForegroundWindow(host);
        popup_check?;
        wait_for(|| aligned(host, overlay), 100)?;
        // Cloaking is a DWM state change, not ShowWindow(SW_HIDE). Exercise
        // the real host state while retaining WS_VISIBLE and host foreground.
        let started = Instant::now();
        let cloak = BOOL(1);
        DwmSetWindowAttribute(
            host,
            DWMWA_CLOAK,
            (&cloak as *const BOOL).cast(),
            std::mem::size_of::<BOOL>() as u32,
        )
        .map_err(|error| format!("cloak setup: {error}"))?;
        let cloak_check = (|| {
            let mut state = 0u32;
            DwmGetWindowAttribute(
                host,
                DWMWA_CLOAKED,
                (&mut state as *mut u32).cast(),
                std::mem::size_of::<u32>() as u32,
            )
            .map_err(|error| format!("cloak query: {error}"))?;
            if GetForegroundWindow() != host {
                return Err("environment: host lost foreground during cloak setup".into());
            }
            if state == 0 || !IsWindowVisible(host).as_bool() {
                return Err("cloak must preserve visible style and report a cloaked state".into());
            }
            wait_for(|| !IsWindowVisible(overlay).as_bool(), 500)?;
            if GetForegroundWindow() != host || !IsWindowVisible(host).as_bool() {
                return Err("environment: host state changed during cloak observation".into());
            }
            if started.elapsed() > Duration::from_millis(500) {
                return Err("cloak trigger-to-hidden exceeded 500 ms".into());
            }
            Ok::<_, String>(started.elapsed())
        })();
        // Restore the fixture even if the acceptance assertion failed.
        let cloak = BOOL(0);
        DwmSetWindowAttribute(
            host,
            DWMWA_CLOAK,
            (&cloak as *const BOOL).cast(),
            std::mem::size_of::<BOOL>() as u32,
        )
        .map_err(|error| format!("uncloak: {error}"))?;
        let cloak_latency = cloak_check?;
        wait_for(|| aligned(host, overlay), 500)?;
        println!(
            "OVERLAY_CLOAK_OK latency_ms={:.3}",
            cloak_latency.as_secs_f64() * 1000.
        );
        let monitor = MonitorFromWindow(host, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if !GetMonitorInfoW(monitor, &mut info).as_bool() {
            return Err("Snap monitor query failed".into());
        }
        if GetForegroundWindow() != host {
            return Err("environment: host lost foreground before Snap".into());
        }
        let keys = [
            (VK_LWIN, KEYBD_EVENT_FLAGS(0)),
            (VK_LEFT, KEYBD_EVENT_FLAGS(0)),
            (VK_LEFT, KEYEVENTF_KEYUP),
            (VK_LWIN, KEYEVENTF_KEYUP),
        ]
        .map(|(key, flags)| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: key,
                    dwFlags: flags,
                    ..Default::default()
                },
            },
        });
        super::fixture::send_owned(host, std::process::id(), &keys, false)?;
        // Allow the shell to finish its Snap animation, then enforce the
        // overlay's independent <=100 ms alignment deadline. Frame margins
        // differ from DWM's visible bounds, so tolerate those only for detecting
        // the shell's half-screen placement; overlay/client error remains <=1.
        wait_for(
            || {
                let mut rect = RECT::default();
                GetWindowRect(host, &mut rect).is_ok()
                    && (rect.left - info.rcWork.left).abs() <= 16
                    && (rect.right - (info.rcWork.left + info.rcWork.right) / 2).abs() <= 16
                    && (rect.top - info.rcWork.top).abs() <= 16
                    && (rect.bottom - info.rcWork.bottom).abs() <= 16
            },
            1000,
        )?;
        // Snap Assist can take foreground. Reactivate only our fixture; never
        // send dismissal keys to shell or another application's window.
        std::thread::sleep(Duration::from_millis(350));
        let _ = SetForegroundWindow(host);
        wait_for(|| GetForegroundWindow() == host, 500).map_err(|_| {
            "environment: fixture could not regain foreground after Snap".to_string()
        })?;
        wait_for(|| aligned(host, overlay), 100)?;
        println!("OVERLAY_SNAP_OK edge_error_px<=1");
        let _ = ShowWindow(host, SW_RESTORE);
        SetWindowPos(
            host,
            None,
            initial.left,
            initial.top,
            initial.right - initial.left,
            initial.bottom - initial.top,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )
        .map_err(|error| error.to_string())?;
        wait_for(|| aligned(host, overlay), 100)?;
        std::fs::create_dir_all("target").map_err(|error| error.to_string())?;
        let durations = samples
            .iter()
            .map(|sample| format!("{:.3}", sample.as_secs_f64() * 1000.))
            .collect::<Vec<_>>()
            .join(",");
        std::fs::write("target/overlay-geometry.json", format!("{{\"dpi\":{},\"sorted_trigger_to_observed_apply_ms\":[{}],\"p95_ms\":{:.3},\"edge_error_bound_px\":1,\"visibility_checks_passed\":true,\"cloak_to_hidden_ms\":{:.3},\"snap_checks_passed\":true}}", GetDpiForWindow(host), durations, p95.as_secs_f64() * 1000., cloak_latency.as_secs_f64() * 1000.)).map_err(|error| error.to_string())?;
        println!("PROBE_GEOMETRY_OK");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_match_observed_after_the_deadline_is_not_acceptance() {
        assert!(
            wait_for(
                || {
                    std::thread::sleep(Duration::from_millis(2));
                    true
                },
                1
            )
            .is_err()
        );
        assert!(wait_for(|| true, 100).is_ok());
    }
}
