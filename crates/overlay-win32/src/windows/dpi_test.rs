//! Same-thread DPI-message regression seam; never changes system settings.
use super::*;

/// Borrowed test target. The probe keeps its GPUI window alive until this drops.
pub struct DpiTestWindow {
    hwnd: HWND,
    thread: PhantomData<Rc<()>>,
}

impl DpiTestWindow {
    pub fn new(handle: WindowHandle<'_>) -> Result<Self, Error> {
        let RawWindowHandle::Win32(handle) = handle.as_raw() else {
            return Err(Error::from_hresult(E_INVALIDARG));
        };
        let hwnd = HWND(handle.hwnd.get() as *mut _);
        // SAFETY: only accept the calling thread's own window.
        unsafe {
            let mut pid = 0;
            let tid = GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid != GetCurrentProcessId() || tid != GetCurrentThreadId() {
                return Err(Error::from_hresult(E_INVALIDARG));
            }
        }
        Ok(Self {
            hwnd,
            thread: PhantomData,
        })
    }

    pub fn inject_same_rect(&self, dpi: u16) -> Result<(), Error> {
        // SAFETY: the probe retains the owning GPUI window. Revalidate before
        // synchronously sending a stack RECT; no pointer escapes SendMessageW.
        unsafe {
            let mut pid = 0;
            let tid = GetWindowThreadProcessId(self.hwnd, Some(&mut pid));
            if pid != GetCurrentProcessId() || tid != GetCurrentThreadId() || dpi == 0 {
                return Err(Error::from_hresult(E_INVALIDARG));
            }
            let mut rect = RECT::default();
            GetWindowRect(self.hwnd, &mut rect)?;
            SendMessageW(
                self.hwnd,
                WM_DPICHANGED,
                Some(WPARAM(usize::from(dpi) | (usize::from(dpi) << 16))),
                Some(LPARAM((&rect as *const RECT) as isize)),
            );
        }
        Ok(())
    }
}
