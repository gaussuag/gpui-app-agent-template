use ::windows::Win32::UI::{HiDpi::*, Input::KeyboardAndMouse::*};
use ::windows::{
    Win32::{
        Foundation::*, Graphics::Gdi::*, System::LibraryLoader::GetModuleHandleW,
        UI::WindowsAndMessaging::*,
    },
    core::w,
};
use std::{
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
static CLICKS: AtomicUsize = AtomicUsize::new(0);
static WHEELS: AtomicUsize = AtomicUsize::new(0);

// SAFETY: Windows calls this on the fixture's message-pump thread. No borrowed
// data is retained and all handles/paint structures are provided by Windows.
unsafe extern "system" fn procedure(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let dc = BeginPaint(hwnd, &mut ps);
                let brush = CreateSolidBrush(COLORREF(0x0030c080));
                FillRect(dc, &ps.rcPaint, brush);
                let _ = DeleteObject(brush.into());
                let _ = EndPaint(hwnd, &ps);
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                CLICKS.fetch_add(1, Ordering::SeqCst);
                println!("FIXTURE_CLICK");
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                WHEELS.fetch_add(1, Ordering::SeqCst);
                println!("FIXTURE_WHEEL");
                LRESULT(0)
            }
            WM_CLOSE => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Run an isolated external host for the feasibility probe.
pub fn run_fixture() -> Result<(), ::windows::core::Error> {
    // SAFETY: class, window and message pump are owned by this thread. No user
    // windows are modified; the fixture ends when its own window closes.
    unsafe {
        let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let instance = GetModuleHandleW(None)?;
        let class = w!("OverlayFeasibilityFixture");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: instance.into(),
            lpszClassName: class,
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 {
            return Err(::windows::core::Error::from_win32());
        }
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            w!("Overlay controlled external host"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            80,
            80,
            820,
            600,
            None,
            None,
            Some(instance.into()),
            None,
        )?;
        let scale = GetDpiForWindow(hwnd) as f64 / 96.0;
        SetWindowPos(
            hwnd,
            None,
            80,
            80,
            (900.0 * scale) as i32,
            (700.0 * scale) as i32,
            SWP_NOACTIVATE | SWP_NOZORDER,
        )?;
        println!("FIXTURE_HWND={}", hwnd.0 as usize);
        let _ = SetForegroundWindow(hwnd);
        let target = hwnd.0 as usize;
        let driver = std::thread::spawn(move || drive_probe(target));
        let mut msg = MSG::default();
        loop {
            let result = GetMessageW(&mut msg, None, 0, 0).0;
            if result == -1 {
                return Err(::windows::core::Error::from_win32());
            }
            if result == 0 {
                break;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if !matches!(driver.join(), Ok(true)) {
            return Err(::windows::core::Error::from_hresult(E_FAIL));
        }
        Ok(())
    }
}

fn drive_probe(target: usize) -> bool {
    let Some(probe) = std::env::args_os().nth(1) else {
        return true;
    };
    let interactive = std::env::args().any(|arg| arg == "--interactive");
    let demo = std::env::args().any(|arg| arg == "--demo");
    let stress = std::env::args().any(|arg| arg == "--stress");
    let geometry = std::env::args().any(|arg| arg == "--geometry");
    let fallback = std::env::args().any(|arg| arg == "--fallback");
    let close_case = std::env::args().find(|arg| {
        matches!(
            arg.as_str(),
            "--host-exit" | "--owner-close" | "--external-close"
        )
    });
    let mut passed = true;
    let mut command = std::process::Command::new(probe);
    command.env("OVERLAY_PROBE_HOST", target.to_string());
    if fallback {
        command.env("OVERLAY_PROBE_DROP_EVENTS", "1");
    }
    if interactive {
        command.arg("--interactive");
    }
    if demo {
        command.arg("--overlay-demo");
    }
    if stress {
        command.arg("--stress");
    }
    if let Some(case) = &close_case {
        command.arg(case);
    }
    let Ok(mut child) = command.spawn() else {
        // SAFETY: release only our fixture on child launch failure.
        unsafe {
            let _ = PostMessageW(Some(HWND(target as *mut _)), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
        return false;
    };
    // Ordinary native smoke retains its 15-second process deadline. The
    // separate 100-window endurance run includes repeated GPUI window creation.
    let deadline = std::time::Instant::now() + Duration::from_secs(if stress { 60 } else { 15 });
    std::thread::sleep(Duration::from_secs(if close_case.is_some() {
        1
    } else {
        3
    }));
    if let Some(case) = &close_case {
        // SAFETY: host belongs to this fixture; every other candidate is
        // filtered to the process started above. No user-owned windows close.
        unsafe {
            let candidate = if case == "--host-exit" {
                Some(HWND(target as *mut _))
            } else {
                let mut owned = (child.id(), Vec::<HWND>::new());
                let _ = EnumWindows(
                    Some(child_windows),
                    LPARAM((&mut owned as *mut (u32, Vec<HWND>)) as isize),
                );
                owned.1.into_iter().find(|window| {
                    let tool =
                        GetWindowLongPtrW(*window, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0;
                    tool == (case == "--external-close")
                })
            };
            passed = candidate.is_some_and(|window| {
                PostMessageW(Some(window), WM_CLOSE, WPARAM(0), LPARAM(0)).is_ok()
            });
            if !passed {
                eprintln!("PROBE_CLOSE_TARGET_FAILED: {case}");
            }
        }
    }
    if demo {
        // SAFETY: enumerate only this fixture's child PID and close only those
        // windows. The driver never sends a close request to other applications.
        unsafe {
            let mut owned = (child.id(), Vec::<HWND>::new());
            let _ = EnumWindows(
                Some(child_windows),
                LPARAM((&mut owned as *mut (u32, Vec<HWND>)) as isize),
            );
            for window in owned.1 {
                let mut rect = RECT::default();
                if GetWindowRect(window, &mut rect).is_ok()
                    && IsWindowVisible(window).as_bool()
                    && let Err(error) = capture_rect("target/overlay-demo.bmp", rect)
                {
                    eprintln!("demo capture: {error}");
                }
                let _ = PostMessageW(Some(window), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
        }
    }
    if !demo
        && !stress
        && !geometry
        && !fallback
        && close_case.is_none()
        && let Err(error) = exercise_input(HWND(target as *mut _), child.id(), interactive)
    {
        eprintln!(
            "{}: {error}",
            if error.starts_with("environment:") {
                "PROBE_ABORTED"
            } else {
                "PROBE_INPUT_FAILED"
            }
        );
        passed = false;
    }
    if geometry || fallback {
        // SAFETY: enumerate candidates only in the child started by this fixture.
        let mut owned = (child.id(), Vec::<HWND>::new());
        unsafe {
            let _ = EnumWindows(
                Some(child_windows),
                LPARAM((&mut owned as *mut (u32, Vec<HWND>)) as isize),
            );
        }
        let result = if fallback {
            super::fallback::run(HWND(target as *mut _), &owned.1)
        } else {
            super::geometry::run(HWND(target as *mut _), &owned.1)
        };
        if let Err(error) = result {
            eprintln!(
                "{}: {error}",
                if error.starts_with("environment:") {
                    "PROBE_ABORTED"
                } else {
                    "PROBE_GEOMETRY_FAILED"
                }
            );
            passed = false;
        }
    }
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                println!("PROBE_EXIT={status}");
                passed &= status.success();
                break;
            }
            Err(error) => {
                eprintln!("PROBE_WAIT_FAILED={error}");
                passed = false;
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            Ok(None) if std::time::Instant::now() >= deadline => {
                eprintln!("PROBE_TIMEOUT");
                passed = false;
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
    // SAFETY: WM_CLOSE is sent only to this fixture's own surviving window.
    unsafe {
        let _ = PostMessageW(Some(HWND(target as *mut _)), WM_CLOSE, WPARAM(0), LPARAM(0));
    }
    passed
}

fn exercise_input(host: HWND, child_pid: u32, interactive: bool) -> Result<(), String> {
    let _dpi = super::host::DpiScope::enter();
    // SAFETY: only our fixture HWND is activated. Every system-input batch below
    // independently checks that the foreground belongs to these test processes.
    unsafe {
        let _ = SetForegroundWindow(host);
        std::thread::sleep(Duration::from_millis(250));
        if GetForegroundWindow() != host {
            return Err(
                "environment: controlled host could not obtain foreground; interactive desktop required".into(),
            );
        }
    }
    capture(
        host,
        if interactive {
            "target/probe-interactive.bmp"
        } else {
            "target/probe-hud.bmp"
        },
    )?;
    click_wheel(
        host,
        child_pid,
        if interactive { (70., 180.) } else { (60., 50.) },
        true,
    )?;
    std::thread::sleep(Duration::from_millis(350));
    let clicks = CLICKS.load(Ordering::SeqCst);
    let wheels = WHEELS.load(Ordering::SeqCst);
    println!("RESULT interactive={interactive} clicks={clicks} wheels={wheels}");
    if interactive {
        if clicks != 0 || wheels != 0 {
            return Err("interactive input leaked to host".into());
        }
        click_wheel(host, child_pid, (140., 266.), false)?;
        std::thread::sleep(Duration::from_millis(200));
        let keys: Vec<_> = "test"
            .encode_utf16()
            .flat_map(|unit| {
                [KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP].map(move |flags| INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wScan: unit,
                            dwFlags: flags,
                            ..Default::default()
                        },
                    },
                })
            })
            .collect();
        send_owned(host, child_pid, &keys, true)?;
        std::thread::sleep(Duration::from_millis(350));
        capture(host, "target/probe-input.bmp")?;
        // The production probe requests HUD after its seven-second input check.
        std::thread::sleep(Duration::from_secs(4));
        click_wheel(host, child_pid, (60., 50.), true)?;
        std::thread::sleep(Duration::from_millis(250));
        capture(host, "target/probe-switched.bmp")?;
    }
    // SAFETY: read-only check of the controlled host and the actual system input
    // counters; no direct posted mouse messages are used to prove passthrough.
    if CLICKS.load(Ordering::SeqCst) != 1
        || WHEELS.load(Ordering::SeqCst) != 1
        || unsafe { GetForegroundWindow() } != host
    {
        return Err(
            "HUD did not deliver exactly one click/wheel with unchanged host foreground".into(),
        );
    }
    println!("PROBE_REAL_INPUT_OK");
    Ok(())
}

fn owned_foreground(host: HWND, child_pid: u32, require_child: bool) -> bool {
    // SAFETY: read-only identity check before each system-input batch.
    unsafe {
        let foreground = GetForegroundWindow();
        let mut pid = 0;
        GetWindowThreadProcessId(foreground, Some(&mut pid));
        (!require_child && foreground == host) || (pid == child_pid && !foreground.is_invalid())
    }
}

pub(super) fn send_owned(
    host: HWND,
    child_pid: u32,
    input: &[INPUT],
    require_child: bool,
) -> Result<(), String> {
    if !owned_foreground(host, child_pid, require_child) {
        return Err("environment: foreground left controlled test windows before input".into());
    }
    // SAFETY: input is supplied by this fixture and the foreground was checked
    // immediately before this batch. The test never targets arbitrary windows.
    let sent = unsafe { SendInput(input, std::mem::size_of::<INPUT>() as i32) };
    if sent != input.len() as u32 {
        return Err(format!("SendInput accepted {sent}/{} events", input.len()));
    }
    Ok(())
}

fn click_wheel(host: HWND, child_pid: u32, point: (f64, f64), wheel: bool) -> Result<(), String> {
    if !owned_foreground(host, child_pid, false) {
        return Err(
            "environment: foreground left controlled windows before pointer positioning".into(),
        );
    }
    // SAFETY: map a client point of our own fixture. Reject occlusion by any
    // unrelated window before moving the cursor or sending a mouse batch.
    unsafe {
        let scale = GetDpiForWindow(host) as f64 / 96.0;
        let mut position = POINT {
            x: (point.0 * scale) as i32,
            y: (point.1 * scale) as i32,
        };
        if !ClientToScreen(host, &mut position).as_bool() {
            return Err("fixture client mapping failed".into());
        }
        let target = WindowFromPoint(position);
        let mut pid = 0;
        GetWindowThreadProcessId(target, Some(&mut pid));
        if target != host && pid != child_pid {
            return Err("environment: input target is occluded by another application".into());
        }
        SetCursorPos(position.x, position.y).map_err(|error| error.to_string())?;
    }
    let flags = [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_WHEEL];
    let input: Vec<_> = flags
        .into_iter()
        .take(if wheel { 3 } else { 2 })
        .map(|flag| INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dwFlags: flag,
                    mouseData: if flag == MOUSEEVENTF_WHEEL { 120 } else { 0 },
                    ..Default::default()
                },
            },
        })
        .collect();
    send_owned(host, child_pid, &input, false)
}

fn capture(host: HWND, path: &str) -> Result<(), String> {
    // SAFETY: capture only our client area, excluding desktop pixels around
    // rounded native borders and any unrelated application behind them.
    unsafe {
        let mut rect = RECT::default();
        GetClientRect(host, &mut rect).map_err(|error| error.to_string())?;
        let mut origin = POINT::default();
        if !ClientToScreen(host, &mut origin).as_bool() {
            return Err("capture client mapping failed".into());
        }
        rect.right += origin.x;
        rect.bottom += origin.y;
        rect.left = origin.x;
        rect.top = origin.y;
        capture_rect(path, rect).map_err(|error| error.to_string())
    }
}

unsafe extern "system" fn child_windows(hwnd: HWND, data: LPARAM) -> ::windows::core::BOOL {
    // SAFETY: the synchronous EnumWindows caller owns this stack tuple.
    unsafe {
        let state = &mut *(data.0 as *mut (u32, Vec<HWND>));
        let mut pid = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == state.0 {
            state.1.push(hwnd);
        }
    }
    TRUE
}

unsafe fn capture_rect(path: &str, rect: RECT) -> std::io::Result<()> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    // SAFETY: temporary GDI objects are selected/restored/deleted synchronously;
    // the bitmap buffer has exactly width * height * 4 bytes.
    unsafe {
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        if !(1..=7680).contains(&width) || !(1..=4320).contains(&height) {
            return Err(std::io::Error::other("invalid capture bounds"));
        }
        let dc = GetDC(None);
        let memory = CreateCompatibleDC(Some(dc));
        let bitmap = CreateCompatibleBitmap(dc, width, height);
        let old = SelectObject(memory, bitmap.into());
        let result = BitBlt(
            memory,
            0,
            0,
            width,
            height,
            Some(dc),
            rect.left,
            rect.top,
            SRCCOPY | CAPTUREBLT,
        );
        SelectObject(memory, old);
        let mut info = BITMAPINFO::default();
        info.bmiHeader.biSize = 40;
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        let mut pixels = vec![0u8; width as usize * height as usize * 4];
        let rows = GetDIBits(
            memory,
            bitmap,
            0,
            height as u32,
            Some(pixels.as_mut_ptr().cast()),
            &mut info,
            DIB_RGB_COLORS,
        );
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(memory);
        ReleaseDC(None, dc);
        if result.is_err() || rows != height {
            return Err(std::io::Error::other("screen capture failed"));
        }
        let mut bmp = Vec::new();
        bmp.extend_from_slice(b"BM");
        bmp.extend_from_slice(&(54u32 + pixels.len() as u32).to_le_bytes());
        bmp.extend_from_slice(&[0; 4]);
        bmp.extend_from_slice(&54u32.to_le_bytes());
        bmp.extend_from_slice(&40u32.to_le_bytes());
        bmp.extend_from_slice(&width.to_le_bytes());
        bmp.extend_from_slice(&(-height).to_le_bytes());
        bmp.extend_from_slice(&1u16.to_le_bytes());
        bmp.extend_from_slice(&32u16.to_le_bytes());
        bmp.extend_from_slice(&[0; 24]);
        bmp.extend_from_slice(&pixels);
        std::fs::write(path, bmp)
    }
}
