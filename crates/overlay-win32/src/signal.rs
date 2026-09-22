use std::{
    future::poll_fn,
    sync::{Arc, Mutex},
    task::{Poll, Waker},
};

/// Coalescing notification for one asynchronous consumer. Payloads live in the
/// session/latest-snapshot owners, so bursts never allocate an event queue.
#[derive(Clone, Default)]
pub struct ChangeSignal(Arc<Mutex<State>>);

#[derive(Default)]
struct State {
    pending: bool,
    waiter: Option<Waker>,
}

impl ChangeSignal {
    pub fn notify(&self) {
        let waiter = {
            let mut state = self.0.lock().unwrap_or_else(|error| error.into_inner());
            state.pending = true;
            state.waiter.take()
        };
        if let Some(waiter) = waiter {
            waiter.wake();
        }
    }

    pub async fn wait(&self) {
        poll_fn(|cx| {
            let mut state = self.0.lock().unwrap_or_else(|error| error.into_inner());
            if std::mem::take(&mut state.pending) {
                state.waiter = None;
                Poll::Ready(())
            } else {
                state.waiter = Some(cx.waker().clone());
                Poll::Pending
            }
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        future::Future,
        pin::pin,
        sync::atomic::{AtomicUsize, Ordering},
        task::{Context, Wake},
    };
    #[derive(Default)]
    struct Counter(AtomicUsize);
    impl Wake for Counter {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    #[test]
    fn early_and_late_notifications_are_coalesced_without_lost_wakes() {
        let signal = ChangeSignal::default();
        let counter = Arc::new(Counter::default());
        let waker = Waker::from(counter.clone());
        let mut cx = Context::from_waker(&waker);
        signal.notify();
        signal.notify();
        assert!(pin!(signal.wait()).poll(&mut cx).is_ready());
        let mut next = pin!(signal.wait());
        assert!(next.as_mut().poll(&mut cx).is_pending());
        signal.notify();
        signal.notify();
        assert_eq!(counter.0.load(Ordering::SeqCst), 1);
        assert!(next.poll(&mut cx).is_ready());
        assert!(pin!(signal.wait()).poll(&mut cx).is_pending());
    }
}
