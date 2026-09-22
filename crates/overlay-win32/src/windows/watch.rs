use super::host;
use crate::{ChangeSignal, ErrorKind, HostSnapshot, HostWindowId, OverlayError};
use ::windows::Win32::{
    Foundation::*,
    System::Threading::GetCurrentThreadId,
    UI::{Accessibility::*, WindowsAndMessaging::*},
};
use std::{
    cell::Cell,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU32, Ordering},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

thread_local! {
    static TARGET: Cell<usize> = const { Cell::new(0) };
    static DIRTY: Cell<bool> = const { Cell::new(false) };
    static DESTROYED: Cell<bool> = const { Cell::new(false) };
}

#[cfg(feature = "test-support")]
thread_local! {
    static DROPPED_EVENTS: Cell<u64> = const { Cell::new(0) };
}

// SAFETY: test-only callback runs on the hook owner thread and merely counts
// discarded notifications. It never forwards them to the production dirty flag.
#[cfg(feature = "test-support")]
unsafe extern "system" fn discard_event(
    _: HWINEVENTHOOK,
    _: u32,
    _: HWND,
    _: i32,
    _: i32,
    _: u32,
    _: u32,
) {
    DROPPED_EVENTS.set(DROPPED_EVENTS.get().saturating_add(1));
}

/// One message-pump thread per session and one bounded latest-snapshot slot.
/// Stop signals are nonblocking; `finish` must run on a background executor.
pub struct HostWatch {
    latest: Arc<Mutex<Option<HostSnapshot>>>,
    stop: Arc<AtomicBool>,
    thread_id: Arc<AtomicU32>,
    worker: Option<JoinHandle<Result<(), OverlayError>>>,
}

impl HostWatch {
    pub fn start(host: HostWindowId, changed: ChangeSignal) -> Result<Self, OverlayError> {
        let latest = Arc::new(Mutex::new(None));
        let stop = Arc::new(AtomicBool::new(false));
        let output = latest.clone();
        let stopped = stop.clone();
        let thread_id = Arc::new(AtomicU32::new(0));
        let worker_id = thread_id.clone();
        let worker = std::thread::Builder::new()
            .name(format!("overlay-host-{}", host.generation()))
            .spawn(move || run(host, &output, &stopped, &worker_id, changed))
            .map_err(|error| host::error(ErrorKind::TrackingFailed, &error.to_string()))?;
        Ok(Self {
            latest,
            stop,
            thread_id,
            worker: Some(worker),
        })
    }

    pub fn take_latest(&self) -> Result<Option<HostSnapshot>, OverlayError> {
        self.latest
            .lock()
            .map(|mut state| state.take())
            .map_err(|_| {
                host::error(
                    ErrorKind::TrackingFailed,
                    "Native tracker state is unavailable.",
                )
            })
    }

    pub fn request_stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        let id = self.thread_id.load(Ordering::SeqCst);
        if id != 0 {
            // SAFETY: this is our worker's published, initialized message queue.
            // A failed post during thread exit is harmless; the stop flag stays set.
            unsafe {
                let _ = PostThreadMessageW(id, WM_NULL, WPARAM(0), LPARAM(0));
            }
        }
    }

    pub fn finish(mut self) -> Result<(), OverlayError> {
        self.request_stop();
        if let Some(worker) = self.worker.take() {
            worker.join().map_err(|_| {
                host::error(
                    ErrorKind::TrackingFailed,
                    "Native tracker panicked during cleanup.",
                )
            })??;
        }
        Ok(())
    }
}
impl Drop for HostWatch {
    fn drop(&mut self) {
        self.request_stop();
    }
}

// SAFETY: callbacks execute on the registering pump thread. They touch only
// thread-local flags; never call GPUI, retain borrowed data, or block.
unsafe extern "system" fn event(
    _: HWINEVENTHOOK,
    event: u32,
    hwnd: HWND,
    object: i32,
    child: i32,
    _: u32,
    _: u32,
) {
    let relevant_host = TARGET.with(|target| target.get() == hwnd.0 as usize);
    if matches!(
        event,
        EVENT_SYSTEM_FOREGROUND | EVENT_OBJECT_REORDER | EVENT_OBJECT_SHOW | EVENT_OBJECT_HIDE
    ) {
        DIRTY.set(true);
    }
    if relevant_host && (event < EVENT_OBJECT_CREATE || (object == 0 && child == 0)) {
        DIRTY.set(true);
        if event == EVENT_OBJECT_DESTROY {
            DESTROYED.set(true);
        }
    }
}

fn run(
    id: HostWindowId,
    output: &Mutex<Option<HostSnapshot>>,
    stop: &AtomicBool,
    thread_id: &AtomicU32,
    changed: ChangeSignal,
) -> Result<(), OverlayError> {
    struct WorkerCount;
    impl Drop for WorkerCount {
        fn drop(&mut self) {
            super::WORKERS.fetch_sub(1, Ordering::SeqCst);
        }
    }
    super::WORKERS.fetch_add(1, Ordering::SeqCst);
    let _worker_count = WorkerCount;
    let _dpi = host::DpiScope::enter();
    TARGET.set(id.raw());
    DIRTY.set(true);
    DESTROYED.set(false);
    // SAFETY: establish this worker's message queue before publishing its ID.
    // SeqCst stop/ID ordering covers shutdown racing queue initialization.
    unsafe {
        let mut message = MSG::default();
        let _ = PeekMessageW(&mut message, None, 0, 0, PM_NOREMOVE);
        thread_id.store(GetCurrentThreadId(), Ordering::SeqCst);
    }
    let ranges = [
        (EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE, id.pid, id.tid),
        (
            EVENT_OBJECT_LOCATIONCHANGE,
            EVENT_OBJECT_LOCATIONCHANGE,
            id.pid,
            id.tid,
        ),
        (
            EVENT_SYSTEM_MINIMIZESTART,
            EVENT_SYSTEM_MINIMIZEEND,
            id.pid,
            id.tid,
        ),
        (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, 0, 0),
        (EVENT_OBJECT_SHOW, EVENT_OBJECT_REORDER, 0, 0),
        (
            EVENT_SYSTEM_MOVESIZESTART,
            EVENT_SYSTEM_MOVESIZEEND,
            id.pid,
            id.tid,
        ),
        (
            EVENT_OBJECT_STATECHANGE,
            EVENT_OBJECT_STATECHANGE,
            id.pid,
            id.tid,
        ),
        (EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED, id.pid, id.tid),
    ];
    let mut hooks = Vec::new();
    let mut setup_error = None;
    let callback: WINEVENTPROC = Some(event);
    #[cfg(feature = "test-support")]
    let callback: WINEVENTPROC = if std::env::var_os("OVERLAY_PROBE_DROP_EVENTS").is_some() {
        DROPPED_EVENTS.set(0);
        Some(discard_event)
    } else {
        callback
    };
    for (first, last, pid, tid) in ranges {
        // SAFETY: this thread owns hooks and pumps messages until it unhooks;
        // callback code is static, and context is thread-local.
        let hook = unsafe {
            SetWinEventHook(first, last, None, callback, pid, tid, WINEVENT_OUTOFCONTEXT)
        };
        if hook.is_invalid() {
            setup_error = Some(OverlayError {
                kind: ErrorKind::TrackingFailed,
                // SAFETY: capture this thread's error immediately after failure.
                native_code: Some(unsafe { GetLastError() }.0 as i32),
                message: "Could not install host event tracking.".into(),
            });
            break;
        }
        hooks.push(hook);
        super::HOOKS.fetch_add(1, Ordering::SeqCst);
    }
    let mut sequence = 0;
    let mut last_sample = Instant::now() - Duration::from_secs(1);
    while !stop.load(Ordering::SeqCst) {
        // SAFETY: pump only this worker thread's message queue. No borrowed
        // references escape DispatchMessage and hook callbacks do not block.
        unsafe {
            let mut message = MSG::default();
            let batch_started = Instant::now();
            for _ in 0..64 {
                if batch_started.elapsed() >= Duration::from_millis(1)
                    || !PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool()
                {
                    break;
                }
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        if (DIRTY.get() && last_sample.elapsed() >= Duration::from_millis(16))
            || last_sample.elapsed() >= Duration::from_millis(250)
            || setup_error.is_some()
            || DESTROYED.get()
        {
            DIRTY.set(false);
            sequence += 1;
            let mut state = host::sample(id, None, sequence);
            if DESTROYED.get() {
                state.terminal = Some(host::error(
                    ErrorKind::HostGone,
                    "Host was destroyed; select it again to create a new session.",
                ));
            }
            if let Some(error) = setup_error.take() {
                state.terminal = Some(error);
            }
            let terminal = state.terminal.is_some();
            if let Ok(mut latest) = output.lock() {
                *latest = Some(state);
            } else {
                break;
            }
            changed.notify();
            last_sample = Instant::now();
            if terminal {
                break;
            } // Terminal slot is never overwritten.
        }
        let interval = Duration::from_millis(if DIRTY.get() { 16 } else { 250 });
        let timeout = interval
            .saturating_sub(last_sample.elapsed())
            .as_millis()
            .max(1) as u32;
        if stop.load(Ordering::SeqCst) {
            break;
        }
        // SAFETY: wait for this thread's hook/stop messages or the fallback
        // deadline. An already-posted stop message also satisfies this wait.
        unsafe {
            let _ = MsgWaitForMultipleObjectsEx(None, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        }
    }
    let mut cleanup_error = None;
    for hook in hooks {
        // SAFETY: every hook is removed on the same thread that installed it,
        // before thread-local callback data becomes unavailable.
        unsafe {
            if !UnhookWinEvent(hook).as_bool() {
                cleanup_error = Some(OverlayError {
                    kind: ErrorKind::TrackingFailed,
                    native_code: Some(GetLastError().0 as i32),
                    message: "Could not remove event hook before tracker thread exit.".into(),
                });
            }
        }
        super::HOOKS.fetch_sub(1, Ordering::SeqCst);
    }
    TARGET.set(0);
    thread_id.store(0, Ordering::SeqCst);
    #[cfg(feature = "test-support")]
    if DROPPED_EVENTS.get() > 0 {
        println!("OVERLAY_DROPPED_EVENTS={}", DROPPED_EVENTS.get());
    }
    match cleanup_error {
        Some(error) => Err(error),
        None => Ok(()),
    }
}
