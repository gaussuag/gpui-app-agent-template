//! Fixed-capacity diagnostics: no callback logging, allocation, or desktop titles.
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PromotionStatus {
    #[default]
    Idle,
    Waiting,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PresentationRecord {
    pub at: Instant,
    pub generation: u64,
    pub intent_id: u64,
    pub foreground: usize,
    pub capture: usize,
    pub host_predecessor: usize,
    pub overlay_predecessor: usize,
    pub wall_time: Duration,
    /// GetThreadTimes accounting delta, not a high-resolution CPU profiler.
    pub cpu_time: Option<Duration>,
    pub placement_writes: u64,
    pub promotion_requests: u64,
    pub promotion: PromotionStatus,
    pub hidden: Option<crate::HiddenReason>,
    pub input_suspended: bool,
    pub failed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PresentationDiagnostics {
    pub reconciliations: u64,
    pub placement_writes: u64,
    pub promotion_requests: u64,
    pub total_cpu_time: Duration,
    pub max_wall_time: Duration,
    records: [Option<PresentationRecord>; 32],
    next: usize,
}
impl Default for PresentationDiagnostics {
    fn default() -> Self {
        Self {
            reconciliations: 0,
            placement_writes: 0,
            promotion_requests: 0,
            total_cpu_time: Duration::ZERO,
            max_wall_time: Duration::ZERO,
            records: [None; 32],
            next: 0,
        }
    }
}
impl PresentationDiagnostics {
    /// Oldest to newest, at most 32 records. Snapshot reads do not trigger work.
    pub fn recent(&self) -> impl Iterator<Item = &PresentationRecord> {
        (0..32).filter_map(move |offset| self.records[(self.next + offset) % 32].as_ref())
    }
    #[cfg(any(windows, test))]
    pub(crate) fn record(&mut self, record: PresentationRecord) {
        self.reconciliations = self.reconciliations.saturating_add(1);
        if let Some(cpu_time) = record.cpu_time {
            self.total_cpu_time = self.total_cpu_time.saturating_add(cpu_time);
        }
        self.max_wall_time = self.max_wall_time.max(record.wall_time);
        self.records[self.next] = Some(record);
        self.next = (self.next + 1) % 32;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn diagnostics_are_bounded_and_keep_chronological_results() {
        let mut state = PresentationDiagnostics::default();
        for intent_id in 0..40 {
            state.record(PresentationRecord {
                at: Instant::now(),
                generation: 1,
                intent_id,
                foreground: 0,
                capture: 0,
                host_predecessor: 0,
                overlay_predecessor: 0,
                wall_time: Duration::from_micros(intent_id),
                cpu_time: Some(Duration::from_micros(1)),
                placement_writes: 0,
                promotion_requests: 0,
                promotion: PromotionStatus::Idle,
                hidden: None,
                input_suspended: false,
                failed: false,
            });
        }
        assert_eq!(state.reconciliations, 40);
        assert_eq!(state.recent().count(), 32);
        assert_eq!(state.recent().next().map(|entry| entry.intent_id), Some(8));
        assert_eq!(state.recent().last().map(|entry| entry.intent_id), Some(39));
        assert_eq!(state.total_cpu_time, Duration::from_micros(40));
        assert_eq!(state.max_wall_time, Duration::from_micros(39));
    }
}
