//! Pure presentation decisions; native observations and effects live in Windows.
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Promotion {
    #[default]
    Idle,
    Waiting(Instant),
    /// Already submitted, completion unknown. Reattach to enable new requests.
    Unknown,
}

impl Promotion {
    pub fn begin(&mut self, now: Instant) -> bool {
        if *self != Self::Idle {
            return false;
        }
        *self = Self::Waiting(now);
        true
    }

    /// Returns true only on the transition that requires an advisory warning.
    /// Matching is sampled before any passive movement of our own anchor.
    pub fn observe(&mut self, now: Instant, eligible: bool, adjacent: bool) -> bool {
        let Self::Waiting(started) = *self else {
            return false;
        };
        if adjacent {
            *self = Self::Idle;
        } else if !eligible || now.saturating_duration_since(started) >= Duration::from_millis(500)
        {
            *self = Self::Unknown;
            return true;
        }
        false
    }

    pub fn hold_anchor(self) -> bool {
        matches!(self, Self::Waiting(_))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Placement {
    Unchanged,
    Top,
    After(usize),
}

/// Preserve the immediate native predecessor, including an invisible window
/// at the topmost boundary. HWND_TOP is not an equivalent insertion request:
/// Windows can clamp a background caller beneath the foreground host.
pub(crate) fn placement(adjacent: bool, same_band: bool, predecessor: Option<usize>) -> Placement {
    if adjacent && same_band {
        return Placement::Unchanged;
    }
    match predecessor {
        Some(handle) => Placement::After(handle),
        _ => Placement::Top,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_predecessor_is_preserved_at_the_foreground_band_boundary() {
        assert_eq!(placement(false, true, Some(7)), Placement::After(7));
        assert_eq!(placement(false, true, Some(8)), Placement::After(8));
        assert_eq!(placement(true, true, Some(7)), Placement::Unchanged);
        assert_eq!(placement(true, false, Some(7)), Placement::After(7));
        assert_eq!(placement(false, true, None), Placement::Top);
    }
    #[test]
    fn one_request_waits_for_observed_order_not_submission_return() {
        let now = Instant::now();
        let mut state = Promotion::default();
        assert!(state.begin(now));
        assert!(!state.begin(now));
        assert!(!state.observe(now, true, false));
        assert!(state.hold_anchor());
        assert!(!state.observe(now, true, true));
        assert!(state.begin(now));
    }
    #[test]
    fn cancelled_or_timed_out_submissions_do_not_queue_retries() {
        for (eligible, elapsed) in [(false, 0), (true, 500)] {
            let now = Instant::now();
            let mut state = Promotion::default();
            assert!(state.begin(now));
            assert!(state.observe(now + Duration::from_millis(elapsed), eligible, false));
            assert!(!state.hold_anchor());
            assert!(!state.begin(now));
            // Moving our anchor back beside the host cannot acknowledge an old request.
            assert!(!state.observe(now, true, true));
            assert_eq!(state, Promotion::Unknown);
        }
    }
}
