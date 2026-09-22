//! End-to-end acceptance with WinEvent callbacks deliberately discarded.
use super::geometry::{aligned, wait_for};
use ::windows::Win32::{Foundation::*, UI::WindowsAndMessaging::*};
use std::time::{Duration, Instant};

pub(super) fn run(host: HWND, candidates: &[HWND]) -> Result<(), String> {
    let _dpi = super::host::DpiScope::enter();
    // SAFETY: the host belongs to this fixture; candidates are filtered to its
    // child PID. Only the host is moved/hidden, and overlay queries are read-only.
    unsafe {
        let _ = SetForegroundWindow(host);
        wait_for(|| GetForegroundWindow() == host, 500)
            .map_err(|_| "environment: fallback host could not gain foreground".to_string())?;
        let overlay = candidates
            .iter()
            .copied()
            .find(|window| GetWindowLongPtrW(*window, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0)
            .ok_or("controlled overlay not found")?;
        wait_for(|| aligned(host, overlay), 500)?;
        let mut initial = RECT::default();
        GetWindowRect(host, &mut initial).map_err(|error| error.to_string())?;
        let mut samples = Vec::new();
        for step in 1..=4 {
            if GetForegroundWindow() != host {
                return Err("environment: foreground changed during fallback measurement".into());
            }
            let started = Instant::now();
            SetWindowPos(
                host,
                None,
                initial.left + step * 20,
                initial.top + step * 10,
                initial.right - initial.left - step * 8,
                initial.bottom - initial.top - step * 6,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )
            .map_err(|error| error.to_string())?;
            wait_for(|| aligned(host, overlay), 500)?;
            let elapsed = started.elapsed();
            if elapsed > Duration::from_millis(500) {
                return Err("fallback geometry exceeded 500 ms".into());
            }
            samples.push(elapsed.as_secs_f64() * 1000.);
        }
        let started = Instant::now();
        let _ = ShowWindow(host, SW_HIDE);
        let hidden = wait_for(|| !IsWindowVisible(overlay).as_bool(), 500);
        let hide_ms = started.elapsed().as_secs_f64() * 1000.;
        // Restore even when hiding failed; normal fixture shutdown still runs.
        let restore_started = Instant::now();
        let _ = ShowWindow(host, SW_RESTORE);
        let _ = SetForegroundWindow(host);
        hidden?;
        if hide_ms > 500. {
            return Err("fallback hide exceeded 500 ms".into());
        }
        wait_for(|| GetForegroundWindow() == host, 500)
            .map_err(|_| "environment: fallback host could not regain foreground".to_string())?;
        wait_for(|| aligned(host, overlay), 500)?;
        let restored = restore_started.elapsed();
        if restored > Duration::from_millis(500) {
            return Err("fallback restore exceeded 500 ms".into());
        }
        std::fs::create_dir_all("target").map_err(|error| error.to_string())?;
        std::fs::write("target/overlay-fallback.json", format!(
            "{{\"move_resize_ms\":{samples:?},\"hide_ms\":{hide_ms:.3},\"restore_ms\":{:.3},\"edge_error_bound_px\":1}}",
            restored.as_secs_f64() * 1000.)).map_err(|error| error.to_string())?;
        println!("PROBE_FALLBACK_OK samples={samples:?} hide_ms={hide_ms:.3}");
        Ok(())
    }
}
