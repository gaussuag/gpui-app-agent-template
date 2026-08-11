//! UI-independent application state and deterministic background work.

/// Commands accepted by [`AppState`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    /// Increase the demo counter by one.
    Increment,
    /// Reset state and invalidate any in-flight work.
    Reset,
    /// Start background work from the current counter value.
    RunWork,
    /// Apply a completed background result.
    WorkFinished(WorkResult),
}

/// Side effects requested by a state transition.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    /// No adapter work is required.
    None,
    /// Cancel the task owned by the UI adapter.
    CancelWork,
    /// Execute deterministic work away from the UI thread.
    RunWork(WorkRequest),
}

/// Immutable state projected to the UI.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    /// Current demo counter.
    pub counter: i64,
    /// Current background-work status.
    pub work_status: WorkStatus,
}

/// Observable lifecycle of the demo background operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkStatus {
    /// No work has run, or state was reset.
    Idle,
    /// Work for the given revision is in progress.
    Running { revision: u64 },
    /// The latest accepted work completed.
    Succeeded { revision: u64, value: u64 },
}

/// Immutable input passed to the background executor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WorkRequest {
    /// Monotonic revision used to reject stale completion.
    pub revision: u64,
    /// State captured when work started.
    pub seed: i64,
}

impl WorkRequest {
    /// Perform deterministic CPU work without touching UI state.
    #[must_use]
    pub fn execute(self) -> WorkResult {
        let mut value = (self.seed as u64) ^ 0x9e37_79b9_7f4a_7c15;
        let iterations = 40_000 + self.seed.unsigned_abs().min(20_000);

        for index in 0..iterations {
            value = value
                .rotate_left(7)
                .wrapping_add(index.wrapping_mul(0x517c_c1b7_2722_0a95));
            value ^= value >> 11;
        }

        WorkResult {
            revision: self.revision,
            value,
        }
    }
}

/// Immutable result returned by background work.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WorkResult {
    /// Revision copied from the request.
    pub revision: u64,
    /// Deterministic demo output.
    pub value: u64,
}

/// Application state machine.
///
/// Callers use only [`Self::dispatch`] and [`Self::snapshot`]. Side effects are
/// returned as values so the GPUI adapter owns execution and lifecycle.
#[derive(Debug)]
pub struct AppState {
    counter: i64,
    next_revision: u64,
    work_status: WorkStatus,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            counter: 0,
            next_revision: 0,
            work_status: WorkStatus::Idle,
        }
    }
}

impl AppState {
    /// Apply one command and return any adapter effect it requests.
    pub fn dispatch(&mut self, command: Command) -> Effect {
        match command {
            Command::Increment => {
                self.counter = self.counter.saturating_add(1);
                Effect::None
            }
            Command::Reset => {
                self.counter = 0;
                self.next_revision = self.next_revision.saturating_add(1);
                self.work_status = WorkStatus::Idle;
                Effect::CancelWork
            }
            Command::RunWork => {
                self.next_revision = self.next_revision.saturating_add(1);
                let request = WorkRequest {
                    revision: self.next_revision,
                    seed: self.counter,
                };
                self.work_status = WorkStatus::Running {
                    revision: request.revision,
                };
                Effect::RunWork(request)
            }
            Command::WorkFinished(result) => {
                if matches!(
                    self.work_status,
                    WorkStatus::Running { revision } if revision == result.revision
                ) {
                    self.work_status = WorkStatus::Succeeded {
                        revision: result.revision,
                        value: result.value,
                    };
                }
                Effect::None
            }
        }
    }

    /// Return a detached snapshot suitable for rendering or serialization.
    #[must_use]
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            counter: self.counter,
            work_status: self.work_status.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request_from(effect: Effect) -> WorkRequest {
        match effect {
            Effect::RunWork(request) => request,
            Effect::None | Effect::CancelWork => panic!("expected RunWork effect"),
        }
    }

    #[test]
    fn increment_and_reset_are_observable_through_snapshot() {
        let mut state = AppState::default();

        assert_eq!(state.dispatch(Command::Increment), Effect::None);
        assert_eq!(state.snapshot().counter, 1);
        assert_eq!(state.dispatch(Command::Reset), Effect::CancelWork);
        assert_eq!(
            state.snapshot(),
            Snapshot {
                counter: 0,
                work_status: WorkStatus::Idle,
            }
        );
    }

    #[test]
    fn only_the_latest_work_revision_can_commit() {
        let mut state = AppState::default();
        let first = request_from(state.dispatch(Command::RunWork));
        let second = request_from(state.dispatch(Command::RunWork));

        state.dispatch(Command::WorkFinished(first.execute()));
        assert_eq!(
            state.snapshot().work_status,
            WorkStatus::Running {
                revision: second.revision,
            }
        );

        let second_result = second.execute();
        state.dispatch(Command::WorkFinished(second_result));
        assert_eq!(
            state.snapshot().work_status,
            WorkStatus::Succeeded {
                revision: second.revision,
                value: second_result.value,
            }
        );
    }

    #[test]
    fn reset_invalidates_a_late_result() {
        let mut state = AppState::default();
        let request = request_from(state.dispatch(Command::RunWork));

        assert_eq!(state.dispatch(Command::Reset), Effect::CancelWork);
        state.dispatch(Command::WorkFinished(request.execute()));

        assert_eq!(state.snapshot().work_status, WorkStatus::Idle);
    }

    #[test]
    fn work_is_deterministic_for_the_same_request() {
        let request = WorkRequest {
            revision: 7,
            seed: 42,
        };

        assert_eq!(request.execute(), request.execute());
    }
}
