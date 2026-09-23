//! Real Win32 effects through WindowBinding, on owned fixture windows only.
//! These tests do not establish cross-process click/focus or visual acceptance.
use super::*;
use ::windows::{
    Win32::{
        System::LibraryLoader::GetModuleHandleW,
        UI::Input::KeyboardAndMouse::{EnableWindow, IsWindowEnabled},
    },
    core::w,
};
use std::num::NonZeroIsize;

thread_local! { static POSITIONS: Cell<u64> = const { Cell::new(0) }; }
// SAFETY: static same-thread fixture callback; no borrowed application data.
unsafe extern "system" fn procedure(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_WINDOWPOSCHANGED {
        POSITIONS.set(POSITIONS.get() + 1);
    }
    unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
}
struct Owned(HWND);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: owned window is dropped on its creating test thread.
        unsafe {
            let _ = DestroyWindow(self.0);
        }
    }
}
fn window(owner: Option<HWND>) -> Result<Owned, Error> {
    // SAFETY: test-owned class/window and optional test-owned modal owner.
    unsafe {
        let instance = GetModuleHandleW(None)?;
        let class = w!("OverlayPresentationAdapterTest");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: instance.into(),
            lpszClassName: class,
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS {
            return Err(Error::from_win32());
        }
        let own = Owned(CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            class,
            w!("Controlled overlay adapter test"),
            WS_POPUP,
            50,
            50,
            200,
            150,
            owner,
            None,
            Some(instance.into()),
            None,
        )?);
        SetWindowPos(
            own.0,
            Some(HWND_TOP),
            0,
            0,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
        )?;
        Ok(own)
    }
}

#[test]
fn passive_order_band_modal_and_idle_updates_use_the_real_binding() -> Result<(), Error> {
    let host = window(None)?;
    let own = window(None)?;
    let third = window(None)?;
    let raw = raw_window_handle::Win32WindowHandle::new(
        NonZeroIsize::new(own.0.0 as isize).ok_or_else(|| Error::from_hresult(E_HANDLE))?,
    );
    // SAFETY: `own` outlives the borrowed handle and binding; all stay on this thread.
    let handle = unsafe { WindowHandle::borrow_raw(RawWindowHandle::Win32(raw)) };
    let mut binding = WindowBinding::bind(handle)?;
    binding.set_mode(InputMode::Interactive)?;
    // SAFETY: all mutated HWNDs belong to this fixture thread. Read-only
    // foreground checks never activate, send input, or target a user window.
    unsafe {
        let foreground = GetForegroundWindow();
        assert_ne!(foreground, host.0, "fixture must exercise an inactive host");
        // Desktop windows may already be interleaved with newly shown
        // NOACTIVATE fixtures. Establish the exact controlled relation first.
        SetWindowPos(
            host.0,
            Some(third.0),
            0,
            0,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
        )?;
        let id = crate::HostWindowId {
            raw: host.0.0 as usize,
            pid: GetCurrentProcessId(),
            tid: GetCurrentThreadId(),
            generation: 991,
        };
        let margins = crate::OverlayMargins::default();
        let sample = binding.apply_host(id, 1, margins, crate::VisibilityPolicy::FollowHost)?;
        assert_eq!(sample.visibility_reason, None);
        assert!(IsWindowVisible(own.0).as_bool());
        assert_eq!(visible_neighbor(own.0, GW_HWNDNEXT), Some(host.0));
        assert_eq!(visible_neighbor(own.0, GW_HWNDPREV), Some(third.0));
        assert_ne!(foreground, own.0);
        for mode in [InputMode::Passthrough, InputMode::Interactive] {
            binding.set_mode(mode)?;
            assert_eq!(
                binding
                    .apply_host(id, 1, margins, crate::VisibilityPolicy::ForegroundOnly)?
                    .visibility_reason,
                Some(crate::HiddenReason::Background)
            );
            assert!(!IsWindowVisible(own.0).as_bool());
            assert_eq!(
                binding
                    .apply_host(id, 1, margins, crate::VisibilityPolicy::FollowHost)?
                    .visibility_reason,
                None
            );
            assert!(IsWindowVisible(own.0).as_bool());
            assert_eq!(visible_neighbor(own.0, GW_HWNDNEXT), Some(host.0));
        }
        POSITIONS.set(0);
        let writes_before_idle = binding.diagnostics().placement_writes;
        for _ in 0..64 {
            binding.apply_host(id, 1, margins, crate::VisibilityPolicy::FollowHost)?;
        }
        assert_eq!(
            POSITIONS.get(),
            0,
            "unchanged presentation must not write geometry/order"
        );
        assert_eq!(binding.diagnostics().placement_writes, writes_before_idle);
        assert_eq!(binding.diagnostics().recent().count(), 32);

        SetWindowPos(
            host.0,
            Some(HWND_TOP),
            0,
            0,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
        )?;
        // Same host sequence: local order invalidation must not be skipped.
        binding.apply_host(id, 1, margins, crate::VisibilityPolicy::FollowHost)?;
        assert_eq!(visible_neighbor(own.0, GW_HWNDNEXT), Some(host.0));
        assert_eq!(visible_neighbor(host.0, GW_HWNDNEXT), Some(third.0));

        // Hidden same-band helpers are not presentation anchors. Real external
        // IME windows can reject SetWindowPos insertion with ACCESS_DENIED.
        let helper = window(None)?;
        let flags = SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE;
        let _ = ShowWindow(helper.0, SW_HIDE);
        SetWindowPos(helper.0, Some(third.0), 0, 0, 0, 0, flags)?;
        SetWindowPos(host.0, Some(helper.0), 0, 0, 0, 0, flags)?;
        assert!(!IsWindowVisible(GetWindow(host.0, GW_HWNDPREV)?).as_bool());
        assert_eq!(visible_neighbor(host.0, GW_HWNDPREV), Some(third.0));
        binding.apply_host(id, 1, margins, crate::VisibilityPolicy::FollowHost)?;
        assert_eq!(
            GetWindow(own.0, GW_HWNDPREV)?,
            third.0,
            "skip hidden same-band helpers when selecting an insertion anchor"
        );
        drop(helper);

        // Hidden boundary anchors must not be skipped or promote an ordinary
        // overlay into the topmost band. Only fixture windows are changed.
        let boundary = window(None)?;
        let _ = ShowWindow(boundary.0, SW_HIDE);
        let flags = SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE;
        SetWindowPos(boundary.0, Some(HWND_TOPMOST), 0, 0, 0, 0, flags)?;
        SetWindowPos(host.0, Some(HWND_TOP), 0, 0, 0, 0, flags)?;
        // IME windows can sit immediately above the ordinary host. Locate the
        // actual topmost boundary before positioning the controlled anchor;
        // placing it after a normal IME window would demote our fixture.
        let mut predecessor = GetWindow(host.0, GW_HWNDPREV)?;
        for _ in 0..128 {
            if GetWindowLongPtrW(predecessor, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST.0 != 0 {
                break;
            }
            predecessor = GetWindow(predecessor, GW_HWNDPREV)?;
        }
        assert_ne!(
            GetWindowLongPtrW(predecessor, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST.0,
            0
        );
        if predecessor != boundary.0 {
            SetWindowPos(boundary.0, Some(predecessor), 0, 0, 0, 0, flags)?;
        }
        assert_ne!(
            GetWindowLongPtrW(boundary.0, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST.0,
            0
        );
        assert_eq!(
            binding
                .apply_host(id, 1, margins, crate::VisibilityPolicy::FollowHost)?
                .visibility_reason,
            None
        );
        assert_eq!(GetWindow(own.0, GW_HWNDPREV)?, boundary.0);
        assert_eq!(visible_neighbor(own.0, GW_HWNDNEXT), Some(host.0));
        assert_eq!(
            GetWindowLongPtrW(own.0, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST.0,
            0
        );
        let writes = binding.diagnostics().placement_writes;
        binding.apply_host(id, 1, margins, crate::VisibilityPolicy::FollowHost)?;
        assert_eq!(binding.diagnostics().placement_writes, writes);
        drop(boundary);

        SetWindowPos(
            host.0,
            Some(HWND_TOPMOST),
            0,
            0,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
        )?;
        binding.apply_host(id, 2, margins, crate::VisibilityPolicy::FollowHost)?;
        assert_ne!(
            GetWindowLongPtrW(own.0, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST.0,
            0
        );
        assert_eq!(visible_neighbor(own.0, GW_HWNDNEXT), Some(host.0));

        let modal = window(Some(host.0))?;
        let _ = EnableWindow(host.0, false);
        let sample = binding.apply_host(id, 3, margins, crate::VisibilityPolicy::FollowHost)?;
        assert!(sample.input_suspended);
        assert!(!IsWindowEnabled(own.0).as_bool());
        assert_eq!(visible_neighbor(own.0, GW_HWNDPREV), Some(modal.0));
        binding.set_mode(InputMode::Passthrough)?;
        binding.set_mode(InputMode::Interactive)?;
        assert!(
            !IsWindowEnabled(own.0).as_bool(),
            "mode changes must retain modal suspension"
        );
        let _ = EnableWindow(host.0, true);
        assert!(
            !binding
                .apply_host(id, 4, margins, crate::VisibilityPolicy::FollowHost)?
                .input_suspended
        );
        assert!(IsWindowEnabled(own.0).as_bool());
        drop(modal);

        SetWindowPos(
            host.0,
            Some(HWND_NOTOPMOST),
            0,
            0,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
        )?;
        binding.apply_host(id, 5, margins, crate::VisibilityPolicy::FollowHost)?;
        assert_eq!(
            GetWindowLongPtrW(own.0, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST.0,
            0
        );
        assert_eq!(visible_neighbor(own.0, GW_HWNDNEXT), Some(host.0));
        let _ = ShowWindow(host.0, SW_HIDE);
        assert_eq!(
            binding
                .apply_host(id, 6, margins, crate::VisibilityPolicy::FollowHost)?
                .visibility_reason,
            Some(crate::HiddenReason::Invisible)
        );
        assert!(!IsWindowVisible(own.0).as_bool());
        let _ = ShowWindow(host.0, SW_SHOWNOACTIVATE);
        assert_eq!(
            binding
                .apply_host(id, 7, margins, crate::VisibilityPolicy::FollowHost)?
                .visibility_reason,
            None
        );
        assert!(IsWindowVisible(own.0).as_bool());
        assert_eq!(GetForegroundWindow(), foreground);
    }
    // The attached top-level host may itself be owned. A root-owner equality
    // check would miss its dialogs or accidentally include its owner's siblings.
    let outer = window(None)?;
    let nested_host = window(Some(outer.0))?;
    let dialog = window(Some(nested_host.0))?;
    let sibling = window(Some(outer.0))?;
    assert!(host::foreground_in_group(dialog.0, nested_host.0, own.0));
    assert!(!host::foreground_in_group(sibling.0, nested_host.0, own.0));
    assert!(host::foreground_in_group(own.0, nested_host.0, own.0));
    assert!(!host::foreground_in_group(
        HWND::default(),
        nested_host.0,
        own.0
    ));
    binding.unbind()?;
    Ok(())
}

fn visible_neighbor(hwnd: HWND, direction: GET_WINDOW_CMD) -> Option<HWND> {
    // SAFETY: fixture read-only verification, bounded independently of production.
    unsafe {
        let mut current = hwnd;
        for _ in 0..128 {
            current = GetWindow(current, direction).ok()?;
            if IsWindowVisible(current).as_bool() {
                return Some(current);
            }
        }
    }
    None
}
