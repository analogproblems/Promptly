//! A live terminal session.
//!
//! A [`Session`] pairs a [`Transport`] (where bytes go: a local shell today,
//! an SSH channel in the next step) with an [`Emulator`] (what the bytes mean).
//! [`pump`] runs the read loop on its own thread and hands frames to whoever
//! is drawing them.

pub mod local;

use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use promptly_term::{
    Emulator, EmulatorEvent, Frame, Palette, SearchHit, SelectKind, TermSize, DEFAULT_SCROLLBACK,
};

pub use local::LocalShell;

/// Where a session's bytes come from and go to.
pub trait Transport: Send {
    fn write(&mut self, data: &[u8]) -> io::Result<()>;
    fn resize(&mut self, size: TermSize) -> io::Result<()>;
    /// Exit code once the other end has gone, if it reports one.
    fn exit_code(&mut self) -> Option<i32>;
    /// Ask the other end to stop. Idempotent.
    fn close(&mut self);
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionKind {
    LocalShell { program: String },
    Ssh { host: String },
}

/// What a session reports to its viewer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionEvent {
    Frame(Frame),
    /// The program asked to put text on the clipboard (OSC 52).
    Clipboard(String),
    /// The other end has gone. No more frames follow.
    Exited {
        code: Option<i32>,
    },
}

pub struct Session {
    kind: SessionKind,
    emulator: Mutex<Emulator>,
    transport: Mutex<Box<dyn Transport>>,
    exited: Mutex<Option<Option<i32>>>,
    /// Counts transports, so a reader left over from a replaced one can tell
    /// it no longer speaks for the session. Changed with `emulator` and
    /// `transport` both locked, so holding either one keeps it still.
    generation: AtomicU64,
}

impl Session {
    pub fn new(
        kind: SessionKind,
        size: TermSize,
        palette: Palette,
        transport: Box<dyn Transport>,
    ) -> Self {
        Self::with_scrollback(kind, size, palette, transport, DEFAULT_SCROLLBACK)
    }

    /// A session whose terminal keeps `scrollback` lines of history.
    pub fn with_scrollback(
        kind: SessionKind,
        size: TermSize,
        palette: Palette,
        transport: Box<dyn Transport>,
        scrollback: usize,
    ) -> Self {
        Self {
            kind,
            emulator: Mutex::new(Emulator::with_scrollback(size, palette, scrollback)),
            transport: Mutex::new(transport),
            exited: Mutex::new(None),
            generation: AtomicU64::new(0),
        }
    }

    pub fn kind(&self) -> &SessionKind {
        &self.kind
    }

    /// `Some(code)` once the other end has gone.
    pub fn exited(&self) -> Option<Option<i32>> {
        *self.exited.lock().unwrap()
    }

    pub fn write(&self, data: &[u8]) -> io::Result<()> {
        self.transport.lock().unwrap().write(data)
    }

    /// Report a mouse event to the program if it asked for mouse events of
    /// that kind. Returns whether it did, so the caller can otherwise
    /// select or scroll locally.
    pub fn mouse(&self, event: promptly_term::MouseEvent) -> io::Result<bool> {
        let Some(bytes) = self.emulator.lock().unwrap().mouse_report(event) else {
            return Ok(false);
        };
        self.write(&bytes)?;
        Ok(true)
    }

    /// Paste text the way the running program expects: wrapped in bracketed
    /// paste markers when it asked for them, with newlines as carriage returns.
    ///
    /// Control characters other than tab and newlines are dropped first, so
    /// pasted text cannot end bracketed paste early (an embedded `ESC[201~`)
    /// or press keys such as Ctrl+C on the user's behalf.
    pub fn paste(&self, text: &str) -> io::Result<()> {
        let text = sanitize_paste(text);
        let bracketed = self.emulator.lock().unwrap().bracketed_paste();
        let mut t = self.transport.lock().unwrap();
        if bracketed {
            t.write(b"\x1b[200~")?;
            t.write(text.as_bytes())?;
            t.write(b"\x1b[201~")
        } else {
            t.write(text.replace("\r\n", "\r").replace('\n', "\r").as_bytes())
        }
    }

    /// Resize, then build the frame that shows the new layout.
    pub fn resize(&self, size: TermSize, emit: impl FnOnce(Frame)) -> io::Result<()> {
        let mut emu = self.emulator.lock().unwrap();
        emu.resize(size);
        let result = self.transport.lock().unwrap().resize(size);
        emit(emu.frame());
        result
    }

    /// Scroll the viewport and build the frame that shows it.
    pub fn scroll(&self, delta: i32, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        emu.scroll(delta);
        emit(emu.frame());
    }

    pub fn scroll_to_bottom(&self, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        emu.scroll_to_bottom();
        emit(emu.frame());
    }

    pub fn set_palette(&self, palette: Palette, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        emu.set_palette(palette);
        emit(emu.frame());
    }

    /// Start a selection at a viewport cell and show it.
    pub fn select_begin(
        &self,
        col: u16,
        line: i32,
        side_right: bool,
        kind: SelectKind,
        emit: impl FnOnce(Frame),
    ) {
        let mut emu = self.emulator.lock().unwrap();
        emu.select_begin(col, line, side_right, kind);
        emit(emu.frame());
    }

    pub fn select_update(&self, col: u16, line: i32, side_right: bool, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        emu.select_update(col, line, side_right);
        emit(emu.frame());
    }

    pub fn select_clear(&self, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        emu.select_clear();
        emit(emu.frame());
    }

    /// The selected text, or `None` when nothing is selected.
    pub fn selection_text(&self) -> Option<String> {
        self.emulator.lock().unwrap().selection_text()
    }

    /// Search the screen and scrollback for plain text, or stop with `None`.
    pub fn search_set(&self, query: Option<&str>, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        emu.search_set(query);
        emit(emu.frame());
    }

    /// Move to the next match, up into history when `backward`.
    pub fn search_step(&self, backward: bool, emit: impl FnOnce(Frame)) -> Option<SearchHit> {
        let mut emu = self.emulator.lock().unwrap();
        let hit = emu.search_step(backward);
        emit(emu.frame());
        hit
    }

    /// The link under a viewport cell, if any.
    pub fn link_at(&self, col: u16, line: i32) -> Option<promptly_term::Link> {
        self.emulator.lock().unwrap().link_at(col, line)
    }

    /// Build a complete frame regardless of what changed.
    pub fn full_frame(&self, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        emu.invalidate();
        emit(emu.frame());
    }

    /// The whole screen as text, for tests and thumbnails.
    pub fn screen_text(&self) -> String {
        self.emulator.lock().unwrap().screen_text()
    }

    pub fn close(&self) {
        self.transport.lock().unwrap().close();
    }

    /// Give the session a new transport after the old one went away, keeping
    /// the screen and scrollback. The new end is told the current size.
    /// Call [`pump`] again afterwards with the new reader.
    pub fn replace_transport(&self, mut transport: Box<dyn Transport>) {
        let emu = self.emulator.lock().unwrap();
        let _ = transport.resize(emu.size());
        let mut old = self.transport.lock().unwrap();
        old.close();
        *old = transport;
        self.generation.fetch_add(1, Ordering::SeqCst);
        *self.exited.lock().unwrap() = None;
    }

    /// Show a message from Promptly itself in the terminal, such as
    /// "connection dropped". It goes through the emulator like program
    /// output and is never sent to the other end.
    pub fn notice(&self, text: &str, emit: impl FnOnce(Frame)) {
        let mut emu = self.emulator.lock().unwrap();
        let _ = emu.feed(text.as_bytes());
        emit(emu.frame());
    }

    fn mark_exited(&self, code: Option<i32>) {
        *self.exited.lock().unwrap() = Some(code);
    }
}

/// Smallest gap between two frames while output is streaming. Reading pauses
/// for the remainder, which lets the pty buffer coalesce bursts (a `cat` of a
/// large file) into a few hundred frames a second at most.
const MIN_FRAME_GAP: Duration = Duration::from_millis(6);

type Emit = Arc<dyn Fn(SessionEvent) + Send + Sync>;

/// Act on what the program asked for: replies go back to it, clipboard
/// writes to the viewer. True when it asked the terminal to exit.
fn deliver(session: &Session, events: Vec<EmulatorEvent>, emit: &Emit) -> bool {
    let mut exit = false;
    for event in events {
        match event {
            EmulatorEvent::PtyWrite(bytes) => {
                if let Err(e) = session.transport.lock().unwrap().write(&bytes) {
                    tracing::warn!("reply to program failed: {e}");
                }
            }
            EmulatorEvent::ClipboardStore(text) => emit(SessionEvent::Clipboard(text)),
            EmulatorEvent::Exit => exit = true,
            EmulatorEvent::Title(_) | EmulatorEvent::Bell => {}
        }
    }
    exit
}

/// Wait out a synchronized update that the program has not ended, then show
/// it anyway. The read loop is blocked waiting for output meanwhile, so this
/// runs on a thread of its own, one at a time per read loop: `armed` is set
/// while it runs, and both sides change it only with the emulator locked.
fn watch_sync(session: Arc<Session>, generation: u64, emit: Emit, armed: Arc<AtomicBool>) {
    let spawned = thread::Builder::new().name("promptly-sync".into()).spawn({
        let armed = armed.clone();
        move || loop {
            let mut emu = session.emulator.lock().unwrap();
            let current = session.generation.load(Ordering::SeqCst) == generation;
            let Some(deadline) = emu.sync_deadline().filter(|_| current) else {
                armed.store(false, Ordering::SeqCst);
                return;
            };
            let now = Instant::now();
            if deadline > now {
                drop(emu);
                thread::sleep(deadline - now);
                continue;
            }
            if let Some(events) = emu.end_stalled_sync(now) {
                let exit = deliver(&session, events, &emit);
                emit(SessionEvent::Frame(emu.frame()));
                if exit {
                    // The read loop sees the end and reports it.
                    session.close();
                }
            }
        }
    });
    if spawned.is_err() {
        armed.store(false, Ordering::SeqCst);
    }
}

/// Run the read loop for `session` on a new thread. `emit` is called with
/// every event, in order, until `Exited`.
pub fn pump(
    session: Arc<Session>,
    mut reader: Box<dyn Read + Send>,
    emit: impl Fn(SessionEvent) + Send + Sync + 'static,
) -> JoinHandle<()> {
    // Taken now, not on the new thread, so a reader handed over just before a
    // reconnect can't adopt the newer transport's number.
    let generation = session.generation.load(Ordering::SeqCst);
    let emit: Emit = Arc::new(emit);
    let sync_watched = Arc::new(AtomicBool::new(false));
    thread::Builder::new()
        .name("promptly-session".into())
        .spawn(move || {
            let current = || session.generation.load(Ordering::SeqCst) == generation;
            let mut buf = vec![0u8; 64 * 1024];
            let mut last = Instant::now();
            // The first frame shows the empty screen with the right size.
            session.full_frame(|f| emit(SessionEvent::Frame(f)));
            loop {
                let n = match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => {
                        // A pty reports EIO when the child has gone; that is a normal exit.
                        if e.raw_os_error() != Some(5) {
                            tracing::warn!("session read failed: {e}");
                        }
                        break;
                    }
                };
                let elapsed = last.elapsed();
                if elapsed < MIN_FRAME_GAP {
                    thread::sleep(MIN_FRAME_GAP - elapsed);
                }
                let mut emu = session.emulator.lock().unwrap();
                if !current() {
                    // Late output from the old connection: not for this screen.
                    return;
                }
                let events = emu.feed(&buf[..n]);
                let exit = deliver(&session, events, &emit);
                emit(SessionEvent::Frame(emu.frame()));
                if exit {
                    // Still ours while the emulator is locked.
                    session.close();
                    break;
                }
                if emu.sync_deadline().is_some() && !sync_watched.swap(true, Ordering::SeqCst) {
                    watch_sync(
                        session.clone(),
                        generation,
                        emit.clone(),
                        sync_watched.clone(),
                    );
                }
                drop(emu);
                last = Instant::now();
            }
            // Locked through the announcement, so a reconnect lands wholly
            // before (and this stays quiet) or wholly after, and the sync
            // watcher finds nothing left to show once it is made.
            let mut emu = session.emulator.lock().unwrap();
            if !current() {
                // The session has a new connection; only the old one ended.
                return;
            }
            // An update the program left open will never be finished, so
            // its last output is shown before the end is announced.
            if let Some(events) = emu.end_sync() {
                deliver(&session, events, &emit);
                emit(SessionEvent::Frame(emu.frame()));
            }
            let mut transport = session.transport.lock().unwrap();
            let code = transport.exit_code();
            session.mark_exited(code);
            emit(SessionEvent::Exited { code });
            drop(transport);
            drop(emu);
        })
        .expect("spawn session thread")
}

/// Text as it may be pasted: everything but C0 and C1 control characters
/// (and DEL), keeping tab, line feed and carriage return.
pub fn sanitize_paste(text: &str) -> String {
    text.chars()
        .filter(|&c| matches!(c, '\t' | '\n' | '\r') || !c.is_control())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn paste_cannot_escape_bracketed_mode_or_press_keys() {
        assert_eq!(sanitize_paste("ls\x1b[201~rm -rf ~\n"), "ls[201~rm -rf ~\n");
        assert_eq!(sanitize_paste("a\x03b\x7fc\u{9b}d"), "abcd");
        assert_eq!(
            sanitize_paste("tab\there\r\nnext ünïcode ✓"),
            "tab\there\r\nnext ünïcode ✓"
        );
    }

    #[test]
    #[cfg(unix)]
    fn local_shell_round_trip() {
        let size = TermSize::new(40, 6);
        let (shell, reader) =
            LocalShell::spawn(size, Some("/bin/sh".into()), None).expect("spawn /bin/sh");
        let session = Arc::new(Session::new(
            SessionKind::LocalShell {
                program: "/bin/sh".into(),
            },
            size,
            Palette::promptly_dark(),
            Box::new(shell),
        ));
        let (tx, rx) = mpsc::channel();
        let _handle = pump(session.clone(), reader, move |e| {
            let _ = tx.send(e);
        });
        session.write(b"echo hello-$((20+22))\n").unwrap();

        // Wait until the output shows up, then exit.
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(SessionEvent::Frame(_)) => {
                    if session.screen_text().contains("hello-42") {
                        break;
                    }
                }
                Ok(other) => panic!("unexpected event before output: {other:?}"),
                Err(_) => {}
            }
            assert!(
                Instant::now() < deadline,
                "shell output never arrived:\n{}",
                session.screen_text()
            );
        }
        session.write(b"exit 7\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match rx.recv_timeout(Duration::from_secs(1)) {
                Ok(SessionEvent::Exited { code }) => {
                    assert_eq!(code, Some(7));
                    break;
                }
                Ok(_) => {}
                Err(_) => assert!(Instant::now() < deadline, "shell never exited"),
            }
        }
        assert_eq!(session.exited(), Some(Some(7)));
    }

    #[test]
    #[cfg(unix)]
    fn a_session_can_take_a_new_transport_and_keep_its_screen() {
        let size = TermSize::new(40, 6);
        let (shell, reader) =
            LocalShell::spawn(size, Some("/bin/sh".into()), None).expect("spawn /bin/sh");
        let session = Arc::new(Session::new(
            SessionKind::LocalShell {
                program: "/bin/sh".into(),
            },
            size,
            Palette::promptly_dark(),
            Box::new(shell),
        ));
        let (tx, rx) = mpsc::channel();
        let emit = move |e| {
            let _ = tx.send(e);
        };
        let _h = pump(session.clone(), reader, emit.clone());
        session.write(b"echo first-$((1+1)); exit\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match rx.recv_timeout(Duration::from_secs(1)) {
                Ok(SessionEvent::Exited { .. }) => break,
                Ok(_) => {}
                Err(_) => assert!(Instant::now() < deadline, "first shell never exited"),
            }
        }
        assert!(session.exited().is_some());
        assert!(session.screen_text().contains("first-2"));

        session.notice("\r\n[dropped]\r\n", |_| {});
        let (shell, reader) =
            LocalShell::spawn(size, Some("/bin/sh".into()), None).expect("spawn /bin/sh");
        session.replace_transport(Box::new(shell));
        assert_eq!(session.exited(), None, "a fresh transport means not exited");
        let _h = pump(session.clone(), reader, emit);
        session.write(b"echo second-$((2+2))\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !session.screen_text().contains("second-4") {
            let _ = rx.recv_timeout(Duration::from_millis(200));
            assert!(
                Instant::now() < deadline,
                "second shell never answered:\n{}",
                session.screen_text()
            );
        }
        let text = session.screen_text();
        assert!(text.contains("first-2"), "old output kept:\n{text}");
        assert!(text.contains("[dropped]"), "notice shown:\n{text}");
        session.write(b"exit\n").unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn a_big_paste_into_a_busy_program_does_not_block_the_caller() {
        let size = TermSize::new(40, 6);
        let (mut shell, _reader) =
            LocalShell::spawn(size, Some("/bin/sh".into()), None).expect("spawn /bin/sh");
        shell.write(b"sleep 5\n").unwrap();
        thread::sleep(Duration::from_millis(200));
        // Far more than a pty holds, while nothing reads it.
        let started = Instant::now();
        shell.write(&vec![b'x'; 1 << 20]).unwrap();
        assert!(started.elapsed() < Duration::from_secs(1));
        shell.close();
    }

    /// A reader fed by a channel; ends when the sender goes.
    struct Feed(mpsc::Receiver<Vec<u8>>);

    impl Read for Feed {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let Ok(bytes) = self.0.recv() else {
                return Ok(0);
            };
            buf[..bytes.len()].copy_from_slice(&bytes);
            Ok(bytes.len())
        }
    }

    /// A transport that goes nowhere.
    struct Nowhere;

    impl Transport for Nowhere {
        fn write(&mut self, _: &[u8]) -> io::Result<()> {
            Ok(())
        }
        fn resize(&mut self, _: TermSize) -> io::Result<()> {
            Ok(())
        }
        fn exit_code(&mut self) -> Option<i32> {
            None
        }
        fn close(&mut self) {}
    }

    #[test]
    fn a_synchronized_update_left_open_is_shown_while_the_program_is_quiet() {
        let session = Arc::new(Session::with_scrollback(
            SessionKind::Ssh { host: "t".into() },
            TermSize::new(20, 3),
            Palette::promptly_dark(),
            Box::new(Nowhere),
            100,
        ));
        let (input, output) = mpsc::channel();
        let (tx, rx) = mpsc::channel();
        let _h = pump(session.clone(), Box::new(Feed(output)), move |e| {
            let _ = tx.send(e);
        });
        // Begin an update, draw, and then say nothing more.
        input.send(b"\x1b[?2026hdrawn".to_vec()).unwrap();
        let started = Instant::now();
        loop {
            match rx.recv_timeout(Duration::from_secs(2)) {
                Ok(SessionEvent::Frame(f)) => {
                    if f.rows_changed.iter().any(|r| r.glyphs[0] == "d") {
                        break;
                    }
                }
                Ok(other) => panic!("unexpected {other:?}"),
                Err(_) => panic!("the screen stayed frozen"),
            }
        }
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(100), "held back first");
        assert!(waited < Duration::from_secs(1), "but not for long");
        assert!(session.screen_text().starts_with("drawn"));
        drop(input);
    }

    /// A reader that hands over what it is given, then fails.
    struct Failing(Option<Vec<u8>>);

    impl Read for Failing {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let Some(bytes) = self.0.take() else {
                return Err(io::Error::new(io::ErrorKind::ConnectionReset, "dropped"));
            };
            buf[..bytes.len()].copy_from_slice(&bytes);
            Ok(bytes.len())
        }
    }

    #[test]
    fn a_program_that_ends_inside_a_synchronized_update_shows_its_last_output_first() {
        // OSC 52 asks for "hi" on the clipboard.
        let last = b"\x1b[?2026hfinal\x1b]52;c;aGk=\x07".to_vec();
        let ends: [Box<dyn Read + Send>; 2] = [
            Box::new(Feed({
                let (input, output) = mpsc::channel();
                input.send(last.clone()).unwrap();
                output
            })),
            Box::new(Failing(Some(last))),
        ];
        for reader in ends {
            let session = Arc::new(Session::with_scrollback(
                SessionKind::Ssh { host: "t".into() },
                TermSize::new(20, 3),
                Palette::promptly_dark(),
                Box::new(Nowhere),
                100,
            ));
            let (tx, rx) = mpsc::channel();
            let _h = pump(session.clone(), reader, move |e| {
                let _ = tx.send(e);
            });
            let (mut shown, mut copied) = (false, false);
            loop {
                match rx.recv_timeout(Duration::from_secs(2)) {
                    Ok(SessionEvent::Frame(f)) => {
                        shown |= f.rows_changed.iter().any(|r| r.glyphs[0] == "f");
                    }
                    Ok(SessionEvent::Clipboard(text)) => copied = text == "hi",
                    Ok(SessionEvent::Exited { .. }) => break,
                    Err(_) => panic!("the end was never announced"),
                }
            }
            assert!(shown, "the last output is on screen before the end");
            assert!(copied, "and its clipboard write delivered");
            // Past the update's timeout: nothing follows the end.
            assert!(rx.recv_timeout(Duration::from_millis(500)).is_err());
        }
    }

    /// A reader that ends when told to.
    struct Gate(mpsc::Receiver<()>);

    impl Read for Gate {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            let _ = self.0.recv();
            Ok(0)
        }
    }

    #[test]
    #[cfg(unix)]
    fn the_old_connection_ending_late_does_not_end_its_replacement() {
        let size = TermSize::new(40, 6);
        let (old_shell, _) =
            LocalShell::spawn(size, Some("/bin/sh".into()), None).expect("spawn /bin/sh");
        let session = Arc::new(Session::new(
            SessionKind::LocalShell {
                program: "/bin/sh".into(),
            },
            size,
            Palette::promptly_dark(),
            Box::new(old_shell),
        ));
        let (release, gate) = mpsc::channel();
        let (tx, rx) = mpsc::channel();
        let old_events = tx.clone();
        let old = pump(session.clone(), Box::new(Gate(gate)), move |e| {
            let _ = old_events.send(e);
        });

        let (shell, reader) =
            LocalShell::spawn(size, Some("/bin/sh".into()), None).expect("spawn /bin/sh");
        session.replace_transport(Box::new(shell));
        let _new = pump(session.clone(), reader, move |e| {
            let _ = tx.send(e);
        });
        release.send(()).unwrap();
        old.join().unwrap();

        session.write(b"echo still-$((3+3))\n").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !session.screen_text().contains("still-6") {
            if let Ok(SessionEvent::Exited { .. }) = rx.recv_timeout(Duration::from_millis(200)) {
                panic!("the replacement was reported as ended");
            }
            assert!(Instant::now() < deadline, "{}", session.screen_text());
        }
        assert_eq!(session.exited(), None);
        session.write(b"exit\n").unwrap();
    }
}
