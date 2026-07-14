//! Long-lived clipboard worker.
//!
//! A single dedicated OS thread owns one persistent [`arboard::Clipboard`]
//! instance for the entire lifetime of the daemon. Persistence matters on
//! Wayland: the `wlr-data-control` / `ext-data-control` protocols serve a value
//! we SET only for as long as the owning `Clipboard` instance stays alive, so we
//! must not create-and-drop a `Clipboard` per operation.
//!
//! There is deliberately NO polling / monitor task — the clipboard is only read
//! once, on demand, when the pointer crosses to a remote client (see
//! `capture.rs`), and only written when a peer pushes its clipboard to us (see
//! `emulation.rs`).

use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread;

use tokio::sync::oneshot;

/// a request to the clipboard worker thread.
enum ClipboardRequest {
    /// read the current clipboard text (best-effort)
    Get {
        reply: oneshot::Sender<Option<String>>,
    },
    /// replace the clipboard text
    Set(String),
}

/// cloneable handle to the clipboard worker thread.
#[derive(Clone)]
pub(crate) struct ClipboardHandle {
    tx: Sender<ClipboardRequest>,
}

impl ClipboardHandle {
    /// Spawn the clipboard worker thread and return a handle to it.
    ///
    /// If a clipboard cannot be created (e.g. no display / no compositor
    /// support) the worker degrades gracefully: [`ClipboardHandle::get`] replies
    /// `None` and [`ClipboardHandle::set`] is a no-op. The daemon keeps running.
    pub(crate) fn new() -> Self {
        let (tx, rx) = channel::<ClipboardRequest>();
        thread::Builder::new()
            .name("clipboard".into())
            .spawn(move || clipboard_worker(rx))
            .expect("failed to spawn clipboard worker thread");
        Self { tx }
    }

    /// Read the remote-pushable clipboard text. Returns `None` if the clipboard
    /// is empty, holds non-text data, the worker is unavailable, or the worker
    /// thread has gone away.
    pub(crate) async fn get(&self) -> Option<String> {
        let (reply, reply_rx) = oneshot::channel();
        if self.tx.send(ClipboardRequest::Get { reply }).is_err() {
            return None;
        }
        reply_rx.await.ok().flatten()
    }

    /// Fire-and-forget: set the local clipboard text.
    pub(crate) fn set(&self, text: String) {
        let _ = self.tx.send(ClipboardRequest::Set(text));
    }
}

fn clipboard_worker(rx: Receiver<ClipboardRequest>) {
    // Create the clipboard ONCE and keep it alive for the lifetime of the
    // thread so values we set keep being served on Wayland.
    let mut clipboard = match arboard::Clipboard::new() {
        Ok(c) => Some(c),
        Err(e) => {
            log::warn!("clipboard unavailable, clipboard sharing disabled: {e}");
            None
        }
    };

    while let Ok(request) = rx.recv() {
        match request {
            ClipboardRequest::Get { reply } => {
                let text = match clipboard.as_mut() {
                    Some(cb) => match cb.get_text() {
                        Ok(text) => Some(text),
                        Err(e) => {
                            log::debug!("failed to read clipboard: {e}");
                            None
                        }
                    },
                    None => None,
                };
                let _ = reply.send(text);
            }
            ClipboardRequest::Set(text) => {
                if let Some(cb) = clipboard.as_mut() {
                    if let Err(e) = cb.set_text(text) {
                        log::warn!("failed to set clipboard: {e}");
                    }
                }
            }
        }
    }
}
