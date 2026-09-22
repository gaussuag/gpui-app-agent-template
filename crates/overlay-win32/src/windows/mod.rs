use ::windows::{
    Win32::{
        Foundation::*,
        System::Threading::*,
        UI::{
            Input::KeyboardAndMouse::{GetCapture, ReleaseCapture},
            Shell::*,
            WindowsAndMessaging::*,
        },
    },
    core::Error,
};
use raw_window_handle::{RawWindowHandle, WindowHandle};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{cell::Cell, marker::PhantomData, rc::Rc};
static WORKERS: AtomicUsize = AtomicUsize::new(0);
static HOOKS: AtomicUsize = AtomicUsize::new(0);
static BINDINGS: AtomicUsize = AtomicUsize::new(0);
pub fn resource_counts() -> crate::ResourceCounts {
    crate::ResourceCounts {
        workers: WORKERS.load(Ordering::SeqCst),
        hooks: HOOKS.load(Ordering::SeqCst),
        bindings: BINDINGS.load(Ordering::SeqCst),
    }
}

#[cfg(feature = "test-support")]
mod dpi_test;
mod fallback;
mod fixture;
mod geometry;
mod host;
mod margins_test;
#[cfg(feature = "test-support")]
mod presentation_probe;
#[cfg(feature = "test-support")]
pub use presentation_probe::run_presentation_probe;
mod watch;
use crate::InputMode;
#[cfg(feature = "test-support")]
pub use dpi_test::DpiTestWindow;
pub use fixture::run_fixture;
pub use host::{list_hosts, resolve_host};
pub use watch::HostWatch;

/// A borrowed native window, restricted to its creating thread; never destroys it.
pub struct WindowBinding {
    hwnd: HWND,
    original: isize,
    original_style: isize,
    callback: Rc<BindingState>,
    last: Option<crate::HostSnapshot>,
    last_margins: crate::OverlayMargins,
    initialized: bool,
    poisoned: bool,
    _thread: PhantomData<Rc<()>>,
}

struct BindingState {
    live: Cell<bool>,
    mode: Cell<InputMode>,
    dpi_pending: Cell<bool>,
}
const SUBCLASS_ID: usize = 0x47505549;

// SAFETY: `data` points to the binding-owned stable allocation. It remains
// alive until this subclass is removed on the same thread, or NCDESTROY runs.
unsafe extern "system" fn subclass(
    hwnd: HWND,
    message: u32,
    wp: WPARAM,
    lp: LPARAM,
    _: usize,
    data: usize,
) -> LRESULT {
    unsafe {
        let state = &*(data as *const BindingState);
        if message == WM_DPICHANGED {
            // GPUI updates its platform scale while forwarding this message,
            // but an unchanged suggested RECT need not generate WM_SIZE.
            // Finish synchronization from apply_host, outside GPUI borrows.
            state.dpi_pending.set(true);
        }
        if message == WM_NCDESTROY {
            state.live.set(false);
            let _ = RemoveWindowSubclass(hwnd, Some(subclass), SUBCLASS_ID);
            let result = DefSubclassProc(hwnd, message, wp, lp);
            // This callback owns one Rc reference until removal or destruction.
            drop(Rc::from_raw(data as *const BindingState));
            BINDINGS.fetch_sub(1, Ordering::SeqCst);
            return result;
        } else if message == WM_MOUSEACTIVATE && state.mode.get() == InputMode::Passthrough {
            return LRESULT(MA_NOACTIVATE as isize);
        } else if message == WM_SYSCOMMAND
            && matches!(wp.0 as u32 & 0xfff0, SC_MOVE | SC_SIZE | SC_MAXIMIZE)
        {
            return LRESULT(0);
        }
        DefSubclassProc(hwnd, message, wp, lp)
    }
}

impl WindowBinding {
    pub fn apply_host(
        &mut self,
        host: crate::HostWindowId,
        sequence: u64,
        margins: crate::OverlayMargins,
    ) -> Result<crate::HostSnapshot, Error> {
        if !self.usable() {
            return Err(Error::from_hresult(E_HANDLE));
        }
        if let Some(last) = &self.last {
            if last.generation != host.generation() {
                return Err(Error::from_hresult(E_INVALIDARG));
            }
            if last.terminal.is_some()
                || sequence < last.sequence
                || (sequence == last.sequence && self.last_margins == margins)
            {
                return Ok(last.clone());
            }
        }
        let _dpi = host::DpiScope::enter();
        let state = host::sample(host, Some(self.hwnd), sequence).with_margins(margins);
        // SAFETY: only this binding's own window is moved. Sampling and apply
        // execute on its creating thread, outside borrowed GPUI contexts.
        unsafe {
            if state.terminal.is_some() || state.visibility_reason.is_some() {
                if IsWindowVisible(self.hwnd).as_bool() {
                    self.hide();
                }
            } else {
                let r = state.physical_overlay_rect;
                let mut actual = RECT::default();
                let position_matches = GetWindowRect(self.hwnd, &mut actual).is_ok()
                    && (actual.left, actual.top, actual.right, actual.bottom)
                        == (r.left, r.top, r.right, r.bottom);
                if !position_matches || !IsWindowVisible(self.hwnd).as_bool() {
                    SetWindowPos(
                        self.hwnd,
                        Some(HWND_TOPMOST),
                        r.left,
                        r.top,
                        r.width(),
                        r.height(),
                        SWP_NOACTIVATE | SWP_SHOWWINDOW,
                    )?;
                }
            }
        }
        if self.usable() && self.callback.dpi_pending.replace(false) {
            // SAFETY: apply_host runs on the creating thread outside GPUI
            // borrows. Re-read this window's client size after the DPI handler
            // and host positioning have completed. Deliver its normal size
            // notification to synchronize GPUI logical viewport and renderer;
            // no geometry, host state or system DPI is changed here.
            unsafe {
                let mut client = RECT::default();
                GetClientRect(self.hwnd, &mut client)?;
                let width = u16::try_from(client.right - client.left)
                    .map_err(|_| Error::from_hresult(E_INVALIDARG))?;
                let height = u16::try_from(client.bottom - client.top)
                    .map_err(|_| Error::from_hresult(E_INVALIDARG))?;
                SendMessageW(
                    self.hwnd,
                    WM_SIZE,
                    Some(WPARAM(SIZE_RESTORED as usize)),
                    Some(LPARAM(width as isize | ((height as isize) << 16))),
                );
            }
        }
        self.last_margins = margins;
        self.last = Some(state.clone());
        Ok(state)
    }

    pub fn bind(handle: WindowHandle<'_>) -> Result<Self, Error> {
        let RawWindowHandle::Win32(handle) = handle.as_raw() else {
            return Err(Error::from_hresult(E_INVALIDARG));
        };
        let hwnd = HWND(handle.hwnd.get() as *mut _);
        // SAFETY: borrowed handle is used synchronously; validate process/thread
        // before changing it, and retain no references to the handle provider.
        unsafe {
            let mut pid = 0;
            let tid = GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid != GetCurrentProcessId() || tid != GetCurrentThreadId() {
                return Err(Error::from_hresult(E_INVALIDARG));
            }
            let callback = Rc::new(BindingState {
                live: Cell::new(true),
                mode: Cell::new(InputMode::Passthrough),
                dpi_pending: Cell::new(false),
            });
            let callback_reference = Rc::into_raw(callback.clone());
            if !SetWindowSubclass(
                hwnd,
                Some(subclass),
                SUBCLASS_ID,
                callback_reference as usize,
            )
            .as_bool()
            {
                drop(Rc::from_raw(callback_reference));
                return Err(Error::from_win32());
            }
            Ok(Self {
                hwnd,
                original: GetWindowLongPtrW(hwnd, GWL_EXSTYLE),
                original_style: GetWindowLongPtrW(hwnd, GWL_STYLE),
                callback: {
                    BINDINGS.fetch_add(1, Ordering::SeqCst);
                    callback
                },
                last: None,
                last_margins: crate::OverlayMargins::default(),
                initialized: false,
                poisoned: false,
                _thread: PhantomData,
            })
        }
    }

    pub fn set_mode(&mut self, mode: InputMode) -> Result<(), Error> {
        // SAFETY: binding is non-Send and validated at creation. Check liveness
        // before applying styles on the GPUI foreground thread.
        unsafe {
            if !self.usable() {
                return Err(Error::from_hresult(E_HANDLE));
            }
            if self.initialized && self.callback.mode.get() == mode {
                return Ok(());
            }
            let mut style = self.original as u32 | WS_EX_TOOLWINDOW.0;
            if mode == InputMode::Passthrough {
                style |= WS_EX_LAYERED.0 | WS_EX_TRANSPARENT.0 | WS_EX_NOACTIVATE.0;
            }
            let current = GetWindowLongPtrW(self.hwnd, GWL_STYLE);
            let previous = GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE);
            let apply = (|| {
                write_style(
                    self.hwnd,
                    GWL_STYLE,
                    (WS_POPUP.0 | (current as u32 & WS_VISIBLE.0)) as isize,
                )?;
                write_style(self.hwnd, GWL_EXSTYLE, style as isize)?;
                if mode == InputMode::Passthrough {
                    SetLayeredWindowAttributes(self.hwnd, COLORREF(0), 255, LWA_ALPHA)?;
                }
                flush_style(self.hwnd)
            })();
            if let Err(error) = apply {
                let rollback = (|| {
                    write_style(self.hwnd, GWL_STYLE, current)?;
                    write_style(self.hwnd, GWL_EXSTYLE, previous)?;
                    if previous as u32 & WS_EX_LAYERED.0 != 0 {
                        SetLayeredWindowAttributes(self.hwnd, COLORREF(0), 255, LWA_ALPHA)?;
                    }
                    flush_style(self.hwnd)
                })();
                if rollback.is_err() {
                    self.poisoned = true;
                    self.hide();
                }
                return Err(error);
            }
            self.callback.mode.set(mode);
            self.initialized = true;
            if mode == InputMode::Passthrough && GetCapture() == self.hwnd {
                let _ = ReleaseCapture();
            }
            Ok(())
        }
    }
}

impl WindowBinding {
    pub fn usable(&self) -> bool {
        self.callback.live.get() && !self.poisoned
    }

    pub fn unbind(&mut self) -> Result<(), Error> {
        if !self.callback.live.get() {
            return Ok(());
        }
        self.hide();
        // SAFETY: same-thread removal releases the native-owned Rc only after
        // the callback is no longer installed. Failure leaves it for NCDESTROY.
        unsafe {
            if !RemoveWindowSubclass(self.hwnd, Some(subclass), SUBCLASS_ID).as_bool() {
                return Err(Error::from_win32());
            }
            drop(Rc::from_raw(Rc::as_ptr(&self.callback)));
            BINDINGS.fetch_sub(1, Ordering::SeqCst);
            self.callback.live.set(false);
            write_style(self.hwnd, GWL_EXSTYLE, self.original)?;
            write_style(
                self.hwnd,
                GWL_STYLE,
                self.original_style & !(WS_VISIBLE.0 as isize),
            )?;
        }
        Ok(())
    }
    /// Return foreground only when this overlay currently owns it. Refusal is
    /// an advisory result; callers must not retry in a focus-stealing loop.
    pub fn return_focus(&self, id: crate::HostWindowId) -> Result<(), Error> {
        if !self.callback.live.get() {
            return Err(Error::from_hresult(E_HANDLE));
        }
        // SAFETY: read-only identity revalidation followed by a single ordinary
        // focus request to the validated host; no input queues are attached.
        unsafe {
            if GetForegroundWindow() != self.hwnd {
                return Ok(());
            }
            if host::sample(id, Some(self.hwnd), 0).terminal.is_some() {
                return Err(Error::from_hresult(E_HANDLE));
            }
            if !SetForegroundWindow(HWND(id.raw() as *mut _)).as_bool() {
                return Err(Error::from_hresult(E_ACCESSDENIED));
            }
        }
        Ok(())
    }

    pub fn hide(&mut self) {
        // SAFETY: creating thread only, checked against native destruction marker.
        unsafe {
            if self.callback.live.get() {
                if GetCapture() == self.hwnd {
                    let _ = ReleaseCapture();
                }
                let _ = ShowWindow(self.hwnd, SW_HIDE);
            }
        }
    }
}

impl Drop for WindowBinding {
    fn drop(&mut self) {
        if let Err(error) = self.unbind() {
            eprintln!(
                "overlay unbind failed; native callback remains owned until destruction: {error}"
            );
        }
    }
}

unsafe fn write_style(hwnd: HWND, index: WINDOW_LONG_PTR_INDEX, style: isize) -> Result<(), Error> {
    // SAFETY: caller validated thread/ownership. Zero is a valid previous value,
    // so the cleared last-error value distinguishes success from failure.
    unsafe {
        SetLastError(WIN32_ERROR(0));
        let previous = SetWindowLongPtrW(hwnd, index, style);
        if previous == 0 && GetLastError().0 != 0 {
            return Err(Error::from_win32());
        }
    }
    Ok(())
}
unsafe fn flush_style(hwnd: HWND) -> Result<(), Error> {
    // SAFETY: own live window, foreground thread, no geometry or activation.
    unsafe {
        SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            0,
            0,
            0,
            0,
            SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE,
        )
    }
}
