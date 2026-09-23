use super::*;
use crate::presentation::{Placement, Promotion, placement};
use ::windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, IsWindowEnabled};
use std::time::{Duration, Instant};

impl WindowBinding {
    /// Local invalidation is independent of the host watch's sequence. Callback
    /// effects are consumed outside GPUI borrows; self-generated messages cause
    /// one subsequent observation, which converges to a no-op.
    pub fn presentation_changed(&self) -> bool {
        self.callback.dirty.get()
    }

    pub fn set_change_signal(&self, signal: crate::ChangeSignal) {
        *self.callback.changed.borrow_mut() = Some(signal);
    }

    pub fn take_warning(&mut self) -> Option<crate::OverlayError> {
        self.warning.take()
    }

    pub fn diagnostics(&self) -> crate::PresentationDiagnostics {
        *self.diagnostics
    }

    pub(super) fn record_presentation(
        &mut self,
        host: crate::HostWindowId,
        state: &crate::HostSnapshot,
        started: Instant,
        cpu_started: Option<Duration>,
        writes: u64,
        promotions: u64,
    ) {
        let cpu_time = thread_cpu_time()
            .zip(cpu_started)
            .map(|(end, start)| end.saturating_sub(start));
        // SAFETY: diagnostic-only OS queries after reconciliation, outside all
        // callbacks/GPUI borrows. No titles, user text, disk writes or allocations.
        let (foreground, capture, host_predecessor, overlay_predecessor) = unsafe {
            (
                GetForegroundWindow().0 as usize,
                GetCapture().0 as usize,
                GetWindow(HWND(host.raw() as *mut _), GW_HWNDPREV)
                    .map(|h| h.0 as usize)
                    .unwrap_or(0),
                GetWindow(self.hwnd, GW_HWNDPREV)
                    .map(|h| h.0 as usize)
                    .unwrap_or(0),
            )
        };
        self.diagnostics.record(crate::PresentationRecord {
            at: started,
            generation: host.generation(),
            intent_id: self.callback.intent_id.get(),
            foreground,
            capture,
            host_predecessor,
            overlay_predecessor,
            wall_time: started.elapsed(),
            cpu_time,
            placement_writes: self.diagnostics.placement_writes.saturating_sub(writes),
            promotion_requests: self
                .diagnostics
                .promotion_requests
                .saturating_sub(promotions),
            promotion: match self.promotion {
                Promotion::Idle => crate::PromotionStatus::Idle,
                Promotion::Waiting(_) => crate::PromotionStatus::Waiting,
                Promotion::Unknown => crate::PromotionStatus::Unknown,
            },
            hidden: state.visibility_reason,
            input_suspended: state.input_suspended,
            failed: self.order_failed || state.terminal.is_some() || self.warning.is_some(),
        });
    }

    pub(super) fn warn_unknown_promotion(&mut self) {
        self.warning = Some(host::error(
            crate::ErrorKind::TrackingFailed,
            "Host promotion completion is unknown. Following continues; reattach to allow new promotion requests. A submitted request may still execute later.",
        ));
    }

    pub(super) fn present(
        &mut self,
        id: crate::HostWindowId,
        state: &mut crate::HostSnapshot,
    ) -> Result<(), Error> {
        let now = Instant::now();
        let target = HWND(id.raw() as *mut _);
        let intent = self.callback.intent.get();
        let epoch = self.callback.cancel_epoch.get();
        // SAFETY: own window on its creating thread. Host identity was sampled
        // immediately before entry; only one explicit gesture permits a foreign
        // asynchronous Z-order write. No owner/parent or input queues are changed.
        unsafe {
            let host_available = state.terminal.is_none()
                && state.visibility_reason.is_none()
                && !state.input_suspended
                && self.callback.mode.get() == InputMode::Interactive;
            let eligible = host_available && GetForegroundWindow() == self.hwnd;
            let adjacent = visible_neighbor(self.hwnd, GW_HWNDNEXT)? == Some(target);
            if self
                .promotion
                .observe(now, eligible && self.promotion_epoch == epoch, adjacent)
            {
                self.warn_unknown_promotion();
            }

            let host_topmost = topmost(target);
            if intent.is_some_and(|(created, generation)| {
                generation == epoch
                    && now.saturating_duration_since(created) <= Duration::from_millis(250)
            }) && eligible
                && !adjacent
                && host_topmost == topmost(self.hwnd)
                && self.promotion.begin(now)
            {
                self.promotion_epoch = epoch;
                self.diagnostics.promotion_requests =
                    self.diagnostics.promotion_requests.saturating_add(1);
                // Accepted limitation: once posted this operation cannot be
                // cancelled. Never resend from a timer or a foreground event.
                if let Err(error) = SetWindowPos(
                    target,
                    Some(self.hwnd),
                    0,
                    0,
                    0,
                    0,
                    SWP_ASYNCWINDOWPOS
                        | SWP_NOACTIVATE
                        | SWP_NOMOVE
                        | SWP_NOSIZE
                        | SWP_NOOWNERZORDER,
                ) {
                    self.promotion = Promotion::Idle;
                    self.warning = Some(crate::OverlayError {
                        kind: crate::ErrorKind::AccessDenied,
                        native_code: Some(error.code().0),
                        message: "Windows declined host promotion; click the host to continue."
                            .into(),
                    });
                }
            }

            if !host_available
                || eligible
                || intent.is_some_and(|(created, generation)| {
                    generation != epoch
                        || now.saturating_duration_since(created) > Duration::from_millis(250)
                })
            {
                self.callback.intent.set(None);
            }
            self.callback.suspended.set(state.input_suspended);
            if IsWindowEnabled(self.hwnd).as_bool() == state.input_suspended {
                if state.input_suspended && GetCapture() == self.hwnd {
                    let _ = ReleaseCapture();
                }
                let _ = EnableWindow(self.hwnd, !state.input_suspended);
            }
            if !self.usable() {
                return Err(Error::from_hresult(E_HANDLE));
            }
            if state.terminal.is_some() || state.visibility_reason.is_some() {
                if IsWindowVisible(self.hwnd).as_bool() {
                    self.hide();
                }
                return Ok(());
            }

            if topmost(self.hwnd) != host_topmost {
                // Hide before band transition: never expose an intermediate
                // global-topmost placement while moving between bands.
                self.hide();
                if !self.usable() {
                    return Err(Error::from_hresult(E_HANDLE));
                }
                self.diagnostics.placement_writes =
                    self.diagnostics.placement_writes.saturating_add(1);
                SetWindowPos(
                    self.hwnd,
                    Some(if host_topmost {
                        HWND_TOPMOST
                    } else {
                        HWND_NOTOPMOST
                    }),
                    0,
                    0,
                    0,
                    0,
                    SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
                )?;
                if !self.usable() {
                    return Err(Error::from_hresult(E_HANDLE));
                }
            }

            let order = if self.promotion.hold_anchor() {
                Placement::Unchanged
            } else {
                let previous = visible_neighbor(target, GW_HWNDPREV)?;
                // Visual adjacency skips hidden helpers, but the insertion
                // anchor must be the immediate native predecessor. Replacing
                // the last topmost predecessor with HWND_TOP is subject to
                // foreground permission and can leave us behind an active host.
                // Skipping hidden predecessors can also cross the band boundary.
                let predecessor = GetWindow(target, GW_HWNDPREV).ok();
                // A hidden overlay is skipped by visual adjacency but can
                // still be the raw predecessor while restoring visibility.
                let predecessor = if predecessor == Some(self.hwnd) {
                    GetWindow(self.hwnd, GW_HWNDPREV).ok()
                } else {
                    predecessor
                };
                placement(
                    previous == Some(self.hwnd),
                    true,
                    predecessor.map(|window| window.0 as usize),
                )
            };
            let r = state.physical_overlay_rect;
            let mut actual = RECT::default();
            let position_matches = GetWindowRect(self.hwnd, &mut actual).is_ok()
                && (actual.left, actual.top, actual.right, actual.bottom)
                    == (r.left, r.top, r.right, r.bottom);
            let visible = IsWindowVisible(self.hwnd).as_bool();
            if position_matches && visible && order == Placement::Unchanged {
                return Ok(());
            }
            let mut flags = SWP_NOACTIVATE;
            if !visible {
                flags |= SWP_SHOWWINDOW;
            }
            if position_matches {
                flags |= SWP_NOMOVE | SWP_NOSIZE;
            }
            let after = match order {
                Placement::Unchanged => {
                    flags |= SWP_NOZORDER;
                    HWND_TOP
                }
                Placement::Top => {
                    if host_topmost {
                        HWND_TOPMOST
                    } else {
                        HWND_TOP
                    }
                }
                Placement::After(raw) => HWND(raw as *mut _),
            };
            self.diagnostics.placement_writes = self.diagnostics.placement_writes.saturating_add(1);
            SetWindowPos(
                self.hwnd,
                Some(after),
                r.left,
                r.top,
                r.width(),
                r.height(),
                flags,
            )?;
        }
        Ok(())
    }
}

// SAFETY: a read-only OS query on an observed window; callers revalidate host
// identity and handle disappearance through their apply failure path.
unsafe fn topmost(hwnd: HWND) -> bool {
    unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOPMOST.0 != 0 }
}

/// Invisible helper windows (including system-created IME owners) do not define
/// visual adjacency. Bound traversal; never rearrange those helper windows.
fn visible_neighbor(mut hwnd: HWND, direction: GET_WINDOW_CMD) -> Result<Option<HWND>, Error> {
    // SAFETY: read-only bounded desktop traversal. No window memory is accessed.
    unsafe {
        for _ in 0..64 {
            let Ok(next) = GetWindow(hwnd, direction) else {
                return Ok(None);
            };
            if next.is_invalid() {
                return Ok(None);
            }
            if IsWindowVisible(next).as_bool() {
                return Ok(Some(next));
            }
            hwnd = next;
        }
    }
    Err(Error::from_hresult(E_FAIL))
}

// Current-thread accounting only. Windows accounting granularity can make short
// samples zero; retain raw aggregate time, never claim precise sub-ms CPU results.
pub(super) fn thread_cpu_time() -> Option<Duration> {
    let mut created = FILETIME::default();
    let mut exited = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    // SAFETY: fixed-size stack outputs for the current thread pseudo handle.
    if unsafe {
        GetThreadTimes(
            GetCurrentThread(),
            &mut created,
            &mut exited,
            &mut kernel,
            &mut user,
        )
    }
    .is_err()
    {
        return None;
    }
    let ticks = |time: FILETIME| ((time.dwHighDateTime as u64) << 32) | time.dwLowDateTime as u64;
    Some(Duration::from_nanos(
        ticks(kernel)
            .saturating_add(ticks(user))
            .saturating_mul(100),
    ))
}
