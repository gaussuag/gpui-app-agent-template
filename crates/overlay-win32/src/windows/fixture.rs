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
static CUSTOM_CHROME: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static CLICKS: AtomicUsize = AtomicUsize::new(0);
static WHEELS: AtomicUsize = AtomicUsize::new(0);

// SAFETY: Windows calls this on the fixture's message-pump thread. No borrowed
// data is retained and all handles/paint structures are provided by Windows.
unsafe extern "system" fn procedure(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_NCCALCSIZE if CUSTOM_CHROME.load(Ordering::Relaxed) => LRESULT(0),
            WM_NCHITTEST if CUSTOM_CHROME.load(Ordering::Relaxed) => {
                let mut rect = RECT::default();
                let _ = GetWindowRect(hwnd, &mut rect);
                let x = (lp.0 as u16 as i16) as i32;
                let y = ((lp.0 >> 16) as u16 as i16) as i32;
                let dpi = GetDpiForWindow(hwnd) as i32;
                let edge = 6 * dpi / 96;
                LRESULT(if x >= rect.right - edge {
                    HTRIGHT
                } else if x < rect.left + edge {
                    HTLEFT
                } else if y < rect.top + edge {
                    HTTOP
                } else if y >= rect.bottom - edge {
                    HTBOTTOM
                } else if y < rect.top + 40 * dpi / 96 {
                    HTCAPTION
                } else {
                    HTCLIENT
                } as isize)
            }

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
        let custom = std::env::args().any(|arg| arg == "--margins");
        CUSTOM_CHROME.store(custom, Ordering::Relaxed);
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            w!("Overlay controlled external host"),
            if custom {
                WS_POPUP | WS_THICKFRAME | WS_VISIBLE
            } else {
                WS_OVERLAPPEDWINDOW | WS_VISIBLE
            },
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
    let preview = std::env::args()
        .any(|arg| matches!(arg.as_str(), "--ime-preview" | "--components-preview"));
    let components =
        std::env::args().any(|arg| matches!(arg.as_str(), "--components" | "--components-preview"));
    let ime = std::env::args().any(|arg| matches!(arg.as_str(), "--ime" | "--ime-preview"));
    let interactive = ime || components || std::env::args().any(|arg| arg == "--interactive");
    let demo = std::env::args().any(|arg| arg == "--demo");
    let stress = std::env::args().any(|arg| arg == "--stress");
    let geometry = std::env::args().any(|arg| arg == "--geometry");
    let fallback = std::env::args().any(|arg| arg == "--fallback");
    let margins_probe = std::env::args().any(|arg| arg == "--margins");
    let dpi_probe = std::env::args().any(|arg| arg == "--dpi");
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
    if margins_probe {
        command.arg("--margins");
    }
    if dpi_probe {
        command.arg("--dpi");
    }
    if interactive {
        command.arg("--interactive");
    }
    if ime {
        command.arg("--ime");
    }
    if preview {
        command.arg(if components {
            "--components-preview"
        } else {
            "--ime-preview"
        });
    }
    if components {
        command.arg("--components");
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
        && !dpi_probe
        && close_case.is_none()
        && !margins_probe
        && let Err(error) = exercise_input(
            HWND(target as *mut _),
            child.id(),
            interactive,
            ime,
            preview,
            components,
        )
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
    if geometry || fallback || margins_probe {
        // SAFETY: enumerate candidates only in the child started by this fixture.
        let mut owned = (child.id(), Vec::<HWND>::new());
        unsafe {
            let _ = EnumWindows(
                Some(child_windows),
                LPARAM((&mut owned as *mut (u32, Vec<HWND>)) as isize),
            );
        }
        let result = if margins_probe {
            super::margins_test::run(HWND(target as *mut _), child.id(), &owned.1)
        } else if fallback {
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

fn exercise_input(
    mut host: HWND,
    child_pid: u32,
    interactive: bool,
    ime: bool,
    preview: bool,
    components: bool,
) -> Result<(), String> {
    let _dpi = super::host::DpiScope::enter();
    if preview {
        // SAFETY: filter to visible windows of the child process we created.
        unsafe {
            let mut owned = (child_pid, Vec::<HWND>::new());
            EnumWindows(
                Some(child_windows),
                LPARAM((&mut owned as *mut (u32, Vec<HWND>)) as isize),
            )
            .map_err(|error| error.to_string())?;
            host = owned
                .1
                .into_iter()
                .find(|window| IsWindowVisible(*window).as_bool())
                .ok_or("ordinary preview window not found")?;
        }
    }
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
    if !preview {
        verify_native_frame_routing(host)?;
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
        if components {
            for (name, point) in [("dialog", (70., 310.)), ("sheet", (150., 310.))] {
                click_wheel(host, child_pid, point, false)?;
                std::thread::sleep(Duration::from_millis(350));
                capture(
                    host,
                    &format!(
                        "target/probe-components-{}-{name}.bmp",
                        if preview { "preview" } else { "overlay" }
                    ),
                )?;
                let keys = [KEYBD_EVENT_FLAGS(0), KEYEVENTF_KEYUP].map(|flags| INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: VK_ESCAPE,
                            dwFlags: flags,
                            ..Default::default()
                        },
                    },
                });
                send_owned(host, child_pid, &keys, true)?;
                std::thread::sleep(Duration::from_millis(350));
            }
            click_wheel(host, child_pid, (140., 180.), false)?;
            std::thread::sleep(Duration::from_millis(350));
            capture(
                host,
                &format!(
                    "target/probe-components-{}-menu.bmp",
                    if preview { "preview" } else { "overlay" }
                ),
            )?;
            // Close with Escape, then reopen and invoke the item. If Escape
            // left the menu open, the next toggle closes it and reset fails.
            let escape = [KEYBD_EVENT_FLAGS(0), KEYEVENTF_KEYUP].map(|flags| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: VK_ESCAPE,
                        dwFlags: flags,
                        ..Default::default()
                    },
                },
            });
            send_owned(host, child_pid, &escape, true)?;
            std::thread::sleep(Duration::from_millis(200));
            click_wheel(host, child_pid, (140., 180.), false)?;
            std::thread::sleep(Duration::from_millis(200));
            click_wheel(host, child_pid, (140., 227.), false)?;
            std::thread::sleep(Duration::from_millis(350));
            click_wheel(host, child_pid, (215., 310.), false)?;
            std::thread::sleep(Duration::from_millis(350));
            capture(
                host,
                &format!(
                    "target/probe-components-{}-notification.bmp",
                    if preview { "preview" } else { "overlay" }
                ),
            )?;
            // SAFETY: query only our fixture/preview client dimensions; actual
            // pointer movement and click still revalidate ownership below.
            let close_point = unsafe {
                let mut rect = RECT::default();
                GetClientRect(host, &mut rect).map_err(|error| error.to_string())?;
                let scale = GetDpiForWindow(host) as f64 / 96.0;
                (f64::from(rect.right - rect.left) / scale - 30., 64.)
            };
            position_owned(host, child_pid, close_point)?;
            std::thread::sleep(Duration::from_millis(200));
            click_wheel(host, child_pid, close_point, false)?;
            std::thread::sleep(Duration::from_millis(300));
            position_owned(host, child_pid, (70., 180.))?;
            std::thread::sleep(Duration::from_millis(800));
            let container = if preview { "preview" } else { "overlay" };
            capture(
                host,
                &format!("target/probe-components-{container}-tooltip.bmp"),
            )?;
            position_owned(host, child_pid, (140., 380.))?;
            let wheel = INPUT {
                r#type: INPUT_MOUSE,
                Anonymous: INPUT_0 {
                    mi: MOUSEINPUT {
                        dwFlags: MOUSEEVENTF_WHEEL,
                        mouseData: (-360_i32) as u32,
                        ..Default::default()
                    },
                },
            };
            send_owned(host, child_pid, &[wheel], true)?;
            std::thread::sleep(Duration::from_millis(250));
            capture(
                host,
                &format!("target/probe-components-{container}-scroll.bmp"),
            )?;
            println!("PROBE_REAL_INPUT_OK");
            return Ok(());
        }
        click_wheel(host, child_pid, (140., 266.), false)?;
        std::thread::sleep(Duration::from_millis(200));
        if ime {
            // SAFETY: query only the current foreground thread's layout. The
            // send_owned guard still revalidates ownership before every batch.
            let language = unsafe {
                let thread = GetWindowThreadProcessId(GetForegroundWindow(), None);
                GetKeyboardLayout(thread).0 as usize & 0xffff
            };
            if language != 0x0804 {
                return Err("environment: IME suite requires Simplified Chinese Microsoft Pinyin in Chinese input mode".into());
            }
            for cancel in [true, false] {
                let keys: Vec<_> = "NIHAO"
                    .bytes()
                    .flat_map(|key| {
                        [KEYBD_EVENT_FLAGS(0), KEYEVENTF_KEYUP].map(move |flags| INPUT {
                            r#type: INPUT_KEYBOARD,
                            Anonymous: INPUT_0 {
                                ki: KEYBDINPUT {
                                    wVk: VIRTUAL_KEY(u16::from(key)),
                                    dwFlags: flags,
                                    ..Default::default()
                                },
                            },
                        })
                    })
                    .collect();
                send_owned(host, child_pid, &keys, true)?;
                std::thread::sleep(Duration::from_millis(400));
                capture(
                    host,
                    if preview {
                        "target/probe-ime-preview-composition.bmp"
                    } else {
                        "target/probe-ime-composition.bmp"
                    },
                )?;
                let keys = [KEYBD_EVENT_FLAGS(0), KEYEVENTF_KEYUP].map(|flags| INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: if cancel { VK_ESCAPE } else { VK_SPACE },
                            dwFlags: flags,
                            ..Default::default()
                        },
                    },
                });
                send_owned(host, child_pid, &keys, true)?;
                std::thread::sleep(Duration::from_millis(200));
            }
            // Exercise the same ordinary Kit focus traversal after committing
            // text. Separate batches let the probe observe the intermediate
            // focus, with ownership rechecked before each chord.
            for shift in [false, true] {
                let mut chord = vec![(VK_TAB, KEYBD_EVENT_FLAGS(0)), (VK_TAB, KEYEVENTF_KEYUP)];
                if shift {
                    chord.insert(0, (VK_SHIFT, KEYBD_EVENT_FLAGS(0)));
                    chord.push((VK_SHIFT, KEYEVENTF_KEYUP));
                }
                let keys: Vec<_> = chord
                    .into_iter()
                    .map(|(key, flags)| INPUT {
                        r#type: INPUT_KEYBOARD,
                        Anonymous: INPUT_0 {
                            ki: KEYBDINPUT {
                                wVk: key,
                                dwFlags: flags,
                                ..Default::default()
                            },
                        },
                    })
                    .collect();
                send_owned(host, child_pid, &keys, true)?;
                std::thread::sleep(Duration::from_millis(200));
            }
        } else {
            let keys: Vec<_> = "test"
                .encode_utf16()
                .flat_map(|unit| {
                    [KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP].map(move |flags| {
                        INPUT {
                            r#type: INPUT_KEYBOARD,
                            Anonymous: INPUT_0 {
                                ki: KEYBDINPUT {
                                    wScan: unit,
                                    dwFlags: flags,
                                    ..Default::default()
                                },
                            },
                        }
                    })
                })
                .collect();
            send_owned(host, child_pid, &keys, true)?;
        }
        std::thread::sleep(Duration::from_millis(350));
        capture(
            host,
            if preview {
                "target/probe-ime-preview-input.bmp"
            } else {
                "target/probe-input.bmp"
            },
        )?;
        if preview {
            println!("PROBE_REAL_INPUT_OK");
            return Ok(());
        }
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

/// Verify system non-client points are still owned by the controlled host.
fn verify_native_frame_routing(host: HWND) -> Result<(), String> {
    // SAFETY: only queries our fixture; no messages or input target user windows.
    unsafe {
        let mut outer = RECT::default();
        let mut client = POINT::default();
        GetWindowRect(host, &mut outer).map_err(|error| error.to_string())?;
        if !ClientToScreen(host, &mut client).as_bool() {
            return Err("fixture client mapping failed".into());
        }
        let x = (outer.left + outer.right) / 2;
        let y = (outer.top + outer.bottom) / 2;
        for (label, point) in [
            (
                "caption",
                POINT {
                    x,
                    y: (outer.top + client.y) / 2,
                },
            ),
            ("left", POINT { x: client.x - 1, y }),
            (
                "right",
                POINT {
                    x: outer.right - (client.x - outer.left),
                    y,
                },
            ),
            (
                "top",
                POINT {
                    x,
                    y: outer.top + 1,
                },
            ),
            (
                "bottom",
                POINT {
                    x,
                    y: outer.bottom - 1,
                },
            ),
        ] {
            let hit = WindowFromPoint(point);
            if hit != host {
                return Err(format!(
                    "native frame {label} blocked: target={hit:?}, host={host:?}"
                ));
            }
        }
    }
    println!("PROBE_NATIVE_FRAME_ROUTING_OK");
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

fn position_owned(host: HWND, child_pid: u32, point: (f64, f64)) -> Result<(), String> {
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
    Ok(())
}

fn click_wheel(host: HWND, child_pid: u32, point: (f64, f64), wheel: bool) -> Result<(), String> {
    position_owned(host, child_pid, point)?;
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
