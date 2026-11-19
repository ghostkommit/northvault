//! Keep synchronous device libraries on one process-lifetime OS thread.
//!
//! macOS HIDAPI binds its global IOHIDManager to the first caller's run loop.
//! Tokio blocking-pool threads can retire while that manager is still alive.
//! All Coldcard calls must therefore go through this worker, including discovery.

use crate::models::WalletError;
use std::sync::{mpsc, OnceLock};

type Job = Box<dyn FnOnce() + Send>;

struct Worker {
    sender: mpsc::Sender<Job>,
}

impl Worker {
    fn start() -> Result<Self, String> {
        let (sender, receiver) = mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("northvault-hardware".into())
            .spawn(move || {
                while let Ok(job) = receiver.recv() {
                    job();
                }
            })
            .map_err(|_| "could not start hardware-wallet worker".to_string())?;
        Ok(Self { sender })
    }

    async fn run<T: Send + 'static>(&self, operation: impl FnOnce() -> T + Send + 'static) -> Result<T, WalletError> {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        self.sender
            .send(Box::new(move || {
                // Do not start a queued device prompt if its caller has gone away.
                if sender.is_closed() {
                    return;
                }
                let result =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(operation)).map_err(|_| WalletError::device("hardware-wallet operation panicked"));
                let _ = sender.send(result);
            }))
            .map_err(|_| WalletError::device("hardware-wallet worker unavailable"))?;
        receiver.await.map_err(|_| WalletError::device("hardware-wallet worker stopped"))?
    }
}

pub async fn run<T: Send + 'static>(operation: impl FnOnce() -> T + Send + 'static) -> Result<T, WalletError> {
    // The sender is never dropped, so idle periods cannot retire the thread or
    // invalidate the run loop retained by the HID library.
    static WORKER: OnceLock<Result<Worker, String>> = OnceLock::new();
    WORKER.get_or_init(Worker::start).as_ref().map_err(WalletError::device)?.run(operation).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_outlives_the_callers_tokio_runtime() {
        let call = || {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            runtime.block_on(run(|| std::thread::current().id())).unwrap()
        };
        assert_eq!(call(), call());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn calls_keep_thread_affinity_across_callers_and_idle_periods() {
        let first = run(|| std::thread::current().id()).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let calls = (0..16).map(|_| tokio::spawn(run(|| std::thread::current().id()))).collect::<Vec<_>>();
        for call in calls {
            assert_eq!(first, call.await.unwrap().unwrap());
        }
    }

    #[tokio::test]
    async fn rust_panic_does_not_retire_the_worker() {
        let worker = Worker::start().unwrap();
        let first = worker.run(|| std::thread::current().id()).await.unwrap();
        assert!(worker.run(|| panic!("test operation")).await.is_err());
        assert_eq!(first, worker.run(|| std::thread::current().id()).await.unwrap());
    }
}
