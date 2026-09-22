//! Isolated counterexample for an uncancellable cross-process Z-order request.
//! No input injection, activation, production binding, or user HWND is involved.
use ::windows::{
    Win32::{Foundation::*, System::LibraryLoader::GetModuleHandleW, UI::WindowsAndMessaging::*},
    core::w,
};
use std::{
    error::Error,
    io::{BufRead, BufReader, Write},
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, Instant},
};

type ProbeResult<T> = Result<T, Box<dyn Error>>;

// SAFETY: a static callback forwards Windows-owned arguments synchronously.
unsafe extern "system" fn procedure(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe { DefWindowProcW(hwnd, message, wp, lp) }
}

struct OwnedWindow(HWND);
impl Drop for OwnedWindow {
    fn drop(&mut self) {
        // SAFETY: each window is created and dropped on this thread.
        unsafe {
            let _ = DestroyWindow(self.0);
        }
    }
}

fn window() -> ProbeResult<OwnedWindow> {
    // SAFETY: this process owns the class, static callback and returned window.
    // No owner/parent or foreign thread is associated with it.
    unsafe {
        let instance = GetModuleHandleW(None)?;
        let class = w!("OverlayPresentationPrimitiveProbe");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: instance.into(),
            lpszClassName: class,
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS {
            return Err(::windows::core::Error::from_win32().into());
        }
        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            class,
            w!("Controlled presentation primitive probe"),
            WS_POPUP,
            40,
            40,
            120,
            90,
            None,
            None,
            Some(instance.into()),
            None,
        )?;
        let owned = OwnedWindow(hwnd);
        SetWindowPos(
            hwnd,
            Some(HWND_TOP),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
        )?;
        Ok(owned)
    }
}

struct HostProcess {
    child: Child,
    output: Receiver<String>,
    reader: Option<std::thread::JoinHandle<()>>,
}
impl Drop for HostProcess {
    fn drop(&mut self) {
        // This guard owns only the child created below, including failure paths.
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}
impl HostProcess {
    fn start() -> ProbeResult<(Self, HWND)> {
        let child = Command::new(std::env::current_exe()?)
            .arg("--paused-host")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let (sender, output) = mpsc::sync_channel(4);
        let mut process = Self {
            child,
            output,
            reader: None,
        };
        let stdout = process.child.stdout.take().ok_or("Missing child stdout")?;
        // Exactly two short protocol lines; child termination closes this pipe.
        process.reader = Some(
            std::thread::Builder::new()
                .name("presentation-probe-output".into())
                .spawn(move || {
                    for line in BufReader::new(stdout).lines().take(2) {
                        match line {
                            Ok(line) => {
                                if sender.send(line).is_err() {
                                    break;
                                }
                            }
                            Err(_) => break,
                        }
                    }
                })?,
        );
        let ready = process.line()?;
        let raw = ready
            .strip_prefix("PAUSED_HOST=")
            .ok_or("Invalid child handshake")?
            .parse::<usize>()?;
        let hwnd = HWND(raw as *mut _);
        // SAFETY: validate the HWND reported by our live child before using it.
        unsafe {
            let mut pid = 0;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid != process.child.id() || !IsWindow(Some(hwnd)).as_bool() {
                return Err("Child HWND identity mismatch".into());
            }
        }
        Ok((process, hwnd))
    }
    fn line(&self) -> ProbeResult<String> {
        Ok(self.output.recv_timeout(Duration::from_secs(5))?)
    }
    fn resume(&mut self) -> ProbeResult<()> {
        let input = self.child.stdin.as_mut().ok_or("Missing child stdin")?;
        writeln!(input, "resume")?;
        input.flush()?;
        if self.line()? != "HOST_PUMPED" {
            return Err("Invalid resume handshake".into());
        }
        Ok(())
    }
}

fn paused_host() -> ProbeResult<()> {
    let _host = window()?;
    println!("PAUSED_HOST={}", _host.0.0 as usize);
    std::io::stdout().flush()?;
    // Intentionally block the fixture UI thread, without pumping sent messages.
    // EOF on controller exit also releases it; no injected remote suspension.
    let mut command = String::new();
    std::io::stdin().read_line(&mut command)?;
    if command.trim() != "resume" {
        return Ok(());
    }
    let until = Instant::now() + Duration::from_millis(300);
    // SAFETY: pump only this child thread's queue; the host stays alive throughout.
    unsafe {
        while Instant::now() < until {
            let mut message = MSG::default();
            for _ in 0..64 {
                if !PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                    break;
                }
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            let _ = MsgWaitForMultipleObjectsEx(None, 10, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        }
    }
    println!("HOST_PUMPED");
    std::io::stdout().flush()?;
    command.clear();
    std::io::stdin().read_line(&mut command)?;
    Ok(())
}

fn above(first: HWND, second: HWND) -> ProbeResult<bool> {
    // SAFETY: read-only bounded traversal of live fixture HWNDs; never modify
    // enumerated third-party windows. A changing chain fails the experiment.
    unsafe {
        let mut cursor = first;
        for _ in 0..64 {
            match GetWindow(cursor, GW_HWNDNEXT) {
                Ok(next) if !next.is_invalid() => {
                    if next == second {
                        return Ok(true);
                    }
                    cursor = next;
                }
                _ => return Ok(false),
            }
        }
    }
    Err("Z-order traversal exceeded its budget".into())
}

fn experiment(submit: bool) -> ProbeResult<bool> {
    let (mut host, hwnd) = HostProcess::start()?;
    let occluder = window()?;
    let overlay = window()?;
    if !above(overlay.0, occluder.0)? || !above(occluder.0, hwnd)? {
        return Err("Initial fixture ordering unavailable; abort, not pass".into());
    }
    if submit {
        let started = Instant::now();
        // SAFETY: only our paused child host is targeted. This is deliberately
        // the candidate under evaluation, NOT a production-safe implementation.
        unsafe {
            SetWindowPos(
                hwnd,
                Some(overlay.0),
                0,
                0,
                0,
                0,
                SWP_ASYNCWINDOWPOS | SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER,
            )?;
        }
        println!("ASYNC_SUBMIT_US={}", started.elapsed().as_micros());
    }
    // Model cancellation AFTER submission. Raising a new fixture changes the
    // visual context; it intentionally does not claim real foreground/input QA.
    let third = window()?;
    if !above(third.0, overlay.0)? || !above(occluder.0, hwnd)? {
        return Err("Paused baseline changed before resume; abort, not pass".into());
    }
    println!("INTENT_EXPIRED_WHILE_HOST_PAUSED submit={submit}");
    host.resume()?;
    let moved = above(hwnd, occluder.0)?;
    let third_preserved = above(third.0, overlay.0)? && above(overlay.0, hwnd)?;
    println!(
        "AFTER_RESUME submit={submit} host_crossed_occluder={moved} third_above_pair={third_preserved}"
    );
    if !third_preserved {
        return Err("Unrelated fixture ordering changed; inconclusive".into());
    }
    Ok(moved)
}

/// Runs a control and a single adversarial primitive experiment. A successful
/// process exit means evidence was collected, NOT that stage zero passed.
pub fn run_presentation_probe() -> ProbeResult<()> {
    if std::env::args().any(|arg| arg == "--paused-host") {
        return paused_host();
    }
    if experiment(false)? {
        return Err("Control moved without a request".into());
    }
    if experiment(true)? {
        println!(
            "PRESENTATION_CANDIDATE_REJECTED: queued host reorder executed after intent expiry"
        );
    } else {
        println!(
            "PRESENTATION_CANDIDATE_UNPROVEN: no late reorder observed; no cancellation guarantee"
        );
    }
    println!(
        "MANUAL_PENDING: first click, actual foreground switch, GPUI capture/IME, drag, modal, desktop, topmost"
    );
    Ok(())
}
