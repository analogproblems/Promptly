//! The file browser's uploads and downloads: the list the transfers bar
//! shows, and the copies still running, which can be cancelled. Kept out
//! of `api/` so the bridge does not expose it.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use crate::api::files::FileTransfer;
use promptly_ssh::files::Staging;

static NEXT_TRANSFER: AtomicU32 = AtomicU32::new(1);

/// Destinations a copy is writing to or tidying up, so a second copy
/// cannot write to the same place, or be undone by the first one's
/// tidying. Shared by every browser, since two can reach the same files.
static BUSY: Mutex<Option<HashSet<Partial>>> = Mutex::new(None);

fn release(dest: &Partial) {
    if let Some(busy) = BUSY.lock().unwrap().as_mut() {
        busy.remove(dest);
    }
}

/// What a stopped copy may have left half written.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Partial {
    Local(PathBuf),
    /// A path on the server named first (`host:port`).
    Remote(String, String),
}

/// A copy still going: how to stop it, and what to tidy up if it is.
struct Running {
    task: tokio::task::JoinHandle<()>,
    partial: Partial,
    /// The names of what it writes beside the destination.
    staging: Staging,
    /// Raised once both ends are open, so the destination has been touched.
    started: Arc<AtomicBool>,
    transfer: Arc<Mutex<FileTransfer>>,
}

/// The progress callback a copy is handed: bytes done, and the total.
pub(crate) type Progress = Box<dyn Fn(u64, u64) + Send + Sync>;

#[derive(Default)]
pub(crate) struct Transfers {
    list: Mutex<Vec<Arc<Mutex<FileTransfer>>>>,
    running: Mutex<HashMap<u32, Running>>,
}

impl Transfers {
    /// Run a copy in the background and return its transfer id. The job
    /// reports progress through the closure it is given, and writes beside
    /// its destination under the names in the staging it is given (which
    /// the tidying gets too, if it is cancelled); its result settles
    /// the transfer, unless the transfer was cancelled first. Refused while
    /// another copy to the same place is running or being tidied up.
    pub(crate) fn spawn<F>(
        self: &Arc<Self>,
        name: String,
        upload: bool,
        partial: Partial,
        job: impl FnOnce(Progress, Staging) -> F,
    ) -> Result<u32, String>
    where
        F: Future<Output = Result<u64, String>> + Send + 'static,
    {
        if !BUSY
            .lock()
            .unwrap()
            .get_or_insert_with(HashSet::new)
            .insert(partial.clone())
        {
            return Err(format!(
                "Another copy to {name} is still running. Wait for it to finish."
            ));
        }
        let tid = NEXT_TRANSFER.fetch_add(1, Ordering::Relaxed);
        let transfer = Arc::new(Mutex::new(FileTransfer {
            id: tid,
            name,
            upload,
            done: 0,
            total: 0,
            finished: false,
            cancelled: false,
            error: None,
        }));
        self.list.lock().unwrap().push(transfer.clone());
        let started = Arc::new(AtomicBool::new(false));
        let progress: Progress = {
            let t = transfer.clone();
            let started = started.clone();
            Box::new(move |done, total| {
                started.store(true, Ordering::Relaxed);
                let mut p = t.lock().unwrap();
                p.done = done;
                p.total = total;
            })
        };
        let staging = Staging::new();
        let future = job(progress, staging.clone());
        let this = self.clone();
        let t = transfer.clone();
        let dest = partial.clone();
        // Held across the spawn, so the job cannot finish before it is listed.
        let mut running = self.running.lock().unwrap();
        let handle = promptly_ssh::runtime().spawn(async move {
            let result = future.await;
            // Gone from the running list means it was cancelled meanwhile,
            // and the cancelling frees the destination once it has tidied.
            if this.running.lock().unwrap().remove(&tid).is_none() {
                return;
            }
            release(&dest);
            let mut p = t.lock().unwrap();
            p.finished = true;
            p.error = result.err();
        });
        running.insert(
            tid,
            Running {
                task: handle,
                partial,
                staging,
                started,
                transfer,
            },
        );
        Ok(tid)
    }

    /// Stop a running copy. Once it has really stopped, `tidy` removes what
    /// it half wrote (if it got as far as writing), and only then does the
    /// transfer show as cancelled, so a retry it makes way for cannot be
    /// caught by the tidying. False when it had already finished.
    pub(crate) fn cancel<F>(
        &self,
        tid: u32,
        tidy: impl FnOnce(Partial, Staging) -> F + Send + 'static,
    ) -> bool
    where
        F: Future<Output = Result<(), String>> + Send + 'static,
    {
        let Some(run) = self.running.lock().unwrap().remove(&tid) else {
            return false;
        };
        run.task.abort();
        promptly_ssh::runtime().spawn(async move {
            // Aborting only asks; the copy may be mid-write until this returns.
            let _ = run.task.await;
            let error = if run.started.load(Ordering::Relaxed) {
                tidy(run.partial.clone(), run.staging.clone())
                    .await
                    .err()
                    .map(|e| {
                        format!("Cancelled, but the part-copied file could not be removed: {e}")
                    })
            } else {
                None
            };
            release(&run.partial);
            let mut t = run.transfer.lock().unwrap();
            t.finished = true;
            t.cancelled = true;
            t.error = error;
        });
        true
    }

    /// Every transfer, oldest first.
    pub(crate) fn snapshot(&self) -> Vec<FileTransfer> {
        self.list
            .lock()
            .unwrap()
            .iter()
            .map(|t| {
                let t = t.lock().unwrap();
                FileTransfer {
                    id: t.id,
                    name: t.name.clone(),
                    upload: t.upload,
                    done: t.done,
                    total: t.total,
                    finished: t.finished,
                    cancelled: t.cancelled,
                    error: t.error.clone(),
                }
            })
            .collect()
    }

    /// Forget finished transfers.
    pub(crate) fn clear_finished(&self) {
        self.list
            .lock()
            .unwrap()
            .retain(|t| !t.lock().unwrap().finished);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn wait_for(what: impl Fn() -> bool) {
        for _ in 0..400 {
            if what() {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("timed out");
    }

    #[test]
    fn a_finished_copy_reports_its_result() {
        let transfers = Arc::new(Transfers::default());
        let tid = transfers
            .spawn(
                "a.txt".into(),
                false,
                Partial::Local("/nowhere/a.txt".into()),
                |progress, _| async move {
                    progress(5, 5);
                    Ok(5)
                },
            )
            .unwrap();
        wait_for(|| transfers.snapshot()[0].finished);
        let s = &transfers.snapshot()[0];
        assert_eq!((s.id, s.done, s.total, s.cancelled), (tid, 5, 5, false));
        assert!(s.error.is_none());
        let (_, never) = tokio::sync::oneshot::channel();
        assert!(
            !transfers.cancel(tid, tidy_recorder(Default::default(), never)),
            "too late to cancel"
        );
        assert!(!transfers.snapshot()[0].cancelled);
        transfers.clear_finished();
        assert!(transfers.snapshot().is_empty());
    }

    #[test]
    fn a_failed_copy_keeps_its_message() {
        let transfers = Arc::new(Transfers::default());
        transfers
            .spawn(
                "b".into(),
                true,
                Partial::Remote("h:22".into(), "/b".into()),
                |_, _| async { Err("The server would not allow that.".to_string()) },
            )
            .unwrap();
        wait_for(|| transfers.snapshot()[0].finished);
        let s = &transfers.snapshot()[0];
        assert_eq!(s.error.as_deref(), Some("The server would not allow that."));
        assert!(!s.cancelled);
    }

    /// A tidy step that records what it was handed and waits to be let go.
    fn tidy_recorder(
        log: Arc<Mutex<Vec<Partial>>>,
        go: tokio::sync::oneshot::Receiver<Result<(), String>>,
    ) -> impl FnOnce(
        Partial,
        Staging,
    ) -> std::pin::Pin<Box<dyn Future<Output = Result<(), String>> + Send>> {
        move |partial, _| {
            Box::pin(async move {
                log.lock().unwrap().push(partial);
                go.await.unwrap_or(Ok(()))
            })
        }
    }

    #[test]
    fn cancelling_stops_the_copy_then_tidies_then_says_so() {
        let transfers = Arc::new(Transfers::default());
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let tid = transfers
            .spawn(
                "big.iso".into(),
                true,
                Partial::Remote("h:22".into(), "/srv/big.iso".into()),
                |progress, _| async move {
                    progress(0, 100);
                    // Never finishes by itself.
                    let _ = rx.await;
                    progress(100, 100);
                    Ok(100)
                },
            )
            .unwrap();
        wait_for(|| transfers.snapshot()[0].total == 100);
        let log = Arc::new(Mutex::new(Vec::new()));
        let (release, go) = tokio::sync::oneshot::channel();
        assert!(transfers.cancel(tid, tidy_recorder(log.clone(), go)));
        wait_for(|| !log.lock().unwrap().is_empty());
        // The job is gone before the tidying starts: its receiver went with it.
        assert!(tx.is_closed());
        assert_eq!(
            *log.lock().unwrap(),
            [Partial::Remote("h:22".into(), "/srv/big.iso".into())]
        );
        // Still tidying, so not yet shown as cancelled, and nothing else may
        // write there yet: the tidying would remove it.
        assert!(!transfers.snapshot()[0].finished);
        let again = |transfers: &Arc<Transfers>| {
            transfers.spawn(
                "big.iso".into(),
                true,
                Partial::Remote("h:22".into(), "/srv/big.iso".into()),
                |_, _| async { Ok(0) },
            )
        };
        assert!(again(&transfers).unwrap_err().contains("still running"));
        // The same path on another server is another place.
        transfers
            .spawn(
                "big.iso".into(),
                true,
                Partial::Remote("other:22".into(), "/srv/big.iso".into()),
                |_, _| async { Ok(0) },
            )
            .unwrap();
        release.send(Ok(())).unwrap();
        wait_for(|| transfers.snapshot()[0].finished);
        let s = &transfers.snapshot()[0];
        assert!(s.cancelled);
        assert_eq!(s.done, 0);
        assert!(s.error.is_none());
        let (_, never) = tokio::sync::oneshot::channel();
        assert!(
            !transfers.cancel(tid, tidy_recorder(log.clone(), never)),
            "only once"
        );
        // Tidied, so the place is free again.
        again(&transfers).unwrap();
        wait_for(|| transfers.snapshot().iter().all(|t| t.finished));
        transfers.clear_finished();
        assert!(transfers.snapshot().is_empty());
    }

    #[test]
    fn a_failed_tidy_is_reported() {
        let transfers = Arc::new(Transfers::default());
        let tid = transfers
            .spawn(
                "x".into(),
                false,
                Partial::Local("/tmp/x".into()),
                |progress, _| async move {
                    progress(1, 10);
                    std::future::pending::<()>().await;
                    Ok(10)
                },
            )
            .unwrap();
        wait_for(|| transfers.snapshot()[0].total == 10);
        let (release, go) = tokio::sync::oneshot::channel();
        release.send(Err("Permission denied".into())).unwrap();
        transfers.cancel(tid, tidy_recorder(Default::default(), go));
        wait_for(|| transfers.snapshot()[0].finished);
        let s = &transfers.snapshot()[0];
        assert!(s.cancelled);
        assert!(s.error.as_deref().unwrap().ends_with("Permission denied"));
    }

    #[test]
    fn a_copy_cancelled_before_it_started_leaves_nothing_to_tidy() {
        let transfers = Arc::new(Transfers::default());
        let (_tx, rx) = tokio::sync::oneshot::channel::<()>();
        let tid = transfers
            .spawn(
                "x".into(),
                true,
                Partial::Remote("h:22".into(), "/srv/x".into()),
                |_, _| async move {
                    let _ = rx.await;
                    Ok(0)
                },
            )
            .unwrap();
        // The server's own file was never written, so it must not be removed.
        let log = Arc::new(Mutex::new(Vec::new()));
        let (_release, go) = tokio::sync::oneshot::channel();
        assert!(transfers.cancel(tid, tidy_recorder(log.clone(), go)));
        wait_for(|| transfers.snapshot()[0].finished);
        assert!(transfers.snapshot()[0].cancelled);
        assert!(log.lock().unwrap().is_empty());
    }
}
