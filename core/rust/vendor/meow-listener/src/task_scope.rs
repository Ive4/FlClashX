use std::future::Future;
use tokio::task::JoinHandle;
use tokio_util::{sync::CancellationToken, task::TaskTracker};

tokio::task_local! {
    static CURRENT: ListenerTasks;
}

#[derive(Clone, Default)]
pub struct ListenerTasks {
    tracker: TaskTracker,
    cancellation: CancellationToken,
}

impl ListenerTasks {
    pub fn spawn<F>(&self, future: F) -> JoinHandle<()>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let cancellation = self.cancellation.clone();
        self.track(async move {
            tokio::select! {
                biased;
                _ = cancellation.cancelled() => {},
                _ = future => {},
            }
        })
    }

    fn track<F>(&self, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        self.tracker.spawn(CURRENT.scope(self.clone(), future))
    }

    pub fn cancel(&self) {
        self.cancellation.cancel();
    }

    pub async fn shutdown(&self) {
        self.cancel();
        self.tracker.close();
        self.tracker.wait().await;
    }
}

pub(crate) fn spawn<F>(future: F) -> JoinHandle<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    match CURRENT.try_with(Clone::clone) {
        Ok(scope) => scope.spawn(future),
        Err(_) => tokio::spawn(future),
    }
}

pub(crate) fn track<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    match CURRENT.try_with(Clone::clone) {
        Ok(scope) => scope.track(future),
        Err(_) => tokio::spawn(future),
    }
}

#[cfg(any(target_os = "linux", test))]
pub(crate) struct AbortOnDrop(pub(crate) tokio::task::AbortHandle);

#[cfg(any(target_os = "linux", test))]
impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}
