//! Terminal sessions for the app: open, write, resize, scroll, close, and a
//! stream of frames to paint.
//!
//! Sessions live in a registry keyed by a small integer id so the Dart side
//! holds nothing but the id. Frames are built under the session's lock and
//! handed to the stream in order.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;
use promptly_session::{pump, LocalShell, Session, SessionEvent, SessionKind};
use promptly_term::{CursorShape, Frame, Palette, SelectKind, TermSize};

struct Entry {
    session: Arc<Session>,
    sink: Mutex<Option<StreamSink<TerminalEvent>>>,
    reader: Mutex<Option<Box<dyn std::io::Read + Send>>>,
}

impl Entry {
    fn emit(&self, event: TerminalEvent) {
        if let Some(sink) = self.sink.lock().unwrap().as_ref() {
            let _ = sink.add(event);
        }
    }
}

static SESSIONS: LazyLock<Mutex<HashMap<u32, Arc<Entry>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_ID: AtomicU32 = AtomicU32::new(1);

fn entry(id: u32) -> Result<Arc<Entry>, String> {
    SESSIONS
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .ok_or_else(|| format!("no session with id {id}"))
}

// ---- Types the UI sees -------------------------------------------------

pub enum TerminalCursorShape {
    Block,
    Underline,
    Beam,
    HollowBlock,
    Hidden,
}

pub struct TerminalCursor {
    /// Row in the viewport; may be outside it while scrolled back.
    pub line: i32,
    pub col: u16,
    pub shape: TerminalCursorShape,
}

/// One changed row as parallel arrays. `flags` bits are documented in
/// `promptly_term::frame::flags`.
pub struct TerminalRow {
    pub line: u16,
    pub glyphs: Vec<String>,
    pub fg: Vec<u32>,
    pub bg: Vec<u32>,
    pub flags: Vec<u16>,
}

pub struct TerminalFrame {
    pub cols: u16,
    pub rows: u16,
    pub full: bool,
    pub rows_changed: Vec<TerminalRow>,
    pub cursor: TerminalCursor,
    pub display_offset: u32,
    pub history_len: u32,
    pub default_fg: u32,
    pub default_bg: u32,
    pub cursor_color: u32,
    pub title: Option<String>,
    pub bell: bool,
    pub app_cursor: bool,
    pub alt_screen: bool,
    pub bracketed_paste: bool,
    pub mouse_reporting: bool,
}

pub enum TerminalEventKind {
    Frame,
    Clipboard,
    Exited,
}

/// How a selection grows from where it started.
pub enum TerminalSelectKind {
    Simple,
    Word,
    Line,
    Block,
}

/// One event from a session. Exactly one of the payload fields is set,
/// according to `kind`. A plain struct rather than an enum with payloads so
/// the Dart side needs no extra code generation.
pub struct TerminalEvent {
    pub kind: TerminalEventKind,
    pub frame: Option<TerminalFrame>,
    pub clipboard: Option<String>,
    pub exit_code: Option<i32>,
}

impl TerminalEvent {
    fn frame(frame: TerminalFrame) -> Self {
        Self {
            kind: TerminalEventKind::Frame,
            frame: Some(frame),
            clipboard: None,
            exit_code: None,
        }
    }
}

pub struct SessionInfo {
    pub id: u32,
    pub label: String,
    pub is_local: bool,
    pub exited: bool,
    pub exit_code: Option<i32>,
}

impl From<Frame> for TerminalFrame {
    fn from(f: Frame) -> Self {
        TerminalFrame {
            cols: f.cols,
            rows: f.rows,
            full: f.full,
            rows_changed: f
                .rows_changed
                .into_iter()
                .map(|r| TerminalRow {
                    line: r.line,
                    glyphs: r.glyphs,
                    fg: r.fg,
                    bg: r.bg,
                    flags: r.flags,
                })
                .collect(),
            cursor: TerminalCursor {
                line: f.cursor.line,
                col: f.cursor.col,
                shape: match f.cursor.shape {
                    CursorShape::Block => TerminalCursorShape::Block,
                    CursorShape::Underline => TerminalCursorShape::Underline,
                    CursorShape::Beam => TerminalCursorShape::Beam,
                    CursorShape::HollowBlock => TerminalCursorShape::HollowBlock,
                    CursorShape::Hidden => TerminalCursorShape::Hidden,
                },
            },
            display_offset: f.display_offset,
            history_len: f.history_len,
            default_fg: f.default_fg,
            default_bg: f.default_bg,
            cursor_color: f.cursor_color,
            title: f.title,
            bell: f.bell,
            app_cursor: f.app_cursor,
            alt_screen: f.alt_screen,
            bracketed_paste: f.bracketed_paste,
            mouse_reporting: f.mouse_reporting,
        }
    }
}

impl From<SessionEvent> for TerminalEvent {
    fn from(e: SessionEvent) -> Self {
        match e {
            SessionEvent::Frame(f) => TerminalEvent::frame(f.into()),
            SessionEvent::Clipboard(t) => TerminalEvent {
                kind: TerminalEventKind::Clipboard,
                frame: None,
                clipboard: Some(t),
                exit_code: None,
            },
            SessionEvent::Exited { code } => TerminalEvent {
                kind: TerminalEventKind::Exited,
                frame: None,
                clipboard: None,
                exit_code: code,
            },
        }
    }
}

/// The palette for a theme id; an unknown id falls back to Promptly Dark so
/// a stale setting never leaves a session without colours.
pub(crate) fn palette_for(theme: &str) -> Palette {
    Palette::builtin(theme).unwrap_or_else(Palette::promptly_dark)
}

/// Put a session into the registry and return its id. Frames start when
/// `terminal_events` subscribes.
pub(crate) fn register_session(
    session: Arc<Session>,
    reader: Box<dyn std::io::Read + Send>,
) -> u32 {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    SESSIONS.lock().unwrap().insert(
        id,
        Arc::new(Entry {
            session,
            sink: Mutex::new(None),
            reader: Mutex::new(Some(reader)),
        }),
    );
    id
}

// ---- Functions ---------------------------------------------------------

/// Start the user's shell (or `program`) in a new session. Frames begin once
/// `terminal_events` is subscribed.
#[frb(sync)]
pub fn terminal_open_local(
    cols: u16,
    rows: u16,
    theme: String,
    program: Option<String>,
    cwd: Option<String>,
) -> Result<u32, String> {
    let size = TermSize::new(cols, rows);
    let (shell, reader) = LocalShell::spawn(size, program, cwd.map(Into::into))
        .map_err(|e| format!("could not start a shell: {e}"))?;
    let kind = SessionKind::LocalShell {
        program: shell.program().to_string(),
    };
    let session = Arc::new(Session::new(
        kind,
        size,
        palette_for(&theme),
        Box::new(shell),
    ));
    Ok(register_session(session, reader))
}

/// Subscribe to a session's frames. Starts the read loop on first call.
pub fn terminal_events(id: u32, sink: StreamSink<TerminalEvent>) -> anyhow::Result<()> {
    let entry = entry(id).map_err(anyhow::Error::msg)?;
    *entry.sink.lock().unwrap() = Some(sink);
    if let Some(reader) = entry.reader.lock().unwrap().take() {
        let session = entry.session.clone();
        let emitter = entry.clone();
        pump(session, reader, move |event| emitter.emit(event.into()));
    } else {
        // Re-subscribed (the view was rebuilt): send the whole screen again.
        entry
            .session
            .full_frame(|f| entry.emit(TerminalEvent::frame(f.into())));
    }
    Ok(())
}

/// Raw bytes to the program: keystrokes already translated by the UI.
#[frb(sync)]
pub fn terminal_write(id: u32, data: Vec<u8>) -> Result<(), String> {
    entry(id)?.session.write(&data).map_err(|e| e.to_string())
}

/// Paste text, honouring bracketed paste mode.
#[frb(sync)]
pub fn terminal_paste(id: u32, text: String) -> Result<(), String> {
    entry(id)?.session.paste(&text).map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn terminal_resize(id: u32, cols: u16, rows: u16) -> Result<(), String> {
    let entry = entry(id)?;
    entry
        .session
        .resize(TermSize::new(cols, rows), |f| {
            entry.emit(TerminalEvent::frame(f.into()))
        })
        .map_err(|e| e.to_string())
}

/// Scroll the viewport by `delta` lines: positive is up into history.
#[frb(sync)]
pub fn terminal_scroll(id: u32, delta: i32) -> Result<(), String> {
    let entry = entry(id)?;
    entry
        .session
        .scroll(delta, |f| entry.emit(TerminalEvent::frame(f.into())));
    Ok(())
}

#[frb(sync)]
pub fn terminal_scroll_to_bottom(id: u32) -> Result<(), String> {
    let entry = entry(id)?;
    entry
        .session
        .scroll_to_bottom(|f| entry.emit(TerminalEvent::frame(f.into())));
    Ok(())
}

/// Switch the session to another theme by id.
#[frb(sync)]
pub fn terminal_set_theme(id: u32, theme: String) -> Result<(), String> {
    let entry = entry(id)?;
    entry.session.set_palette(palette_for(&theme), |f| {
        entry.emit(TerminalEvent::frame(f.into()))
    });
    Ok(())
}

/// Start a selection at a viewport cell (`line` 0 is the top row).
/// `side_right` is true when the pointer is in the right half of the cell.
#[frb(sync)]
pub fn terminal_select_begin(
    id: u32,
    col: u16,
    line: i32,
    side_right: bool,
    kind: TerminalSelectKind,
) -> Result<(), String> {
    let entry = entry(id)?;
    let kind = match kind {
        TerminalSelectKind::Simple => SelectKind::Simple,
        TerminalSelectKind::Word => SelectKind::Word,
        TerminalSelectKind::Line => SelectKind::Line,
        TerminalSelectKind::Block => SelectKind::Block,
    };
    entry
        .session
        .select_begin(col, line, side_right, kind, |f| {
            entry.emit(TerminalEvent::frame(f.into()))
        });
    Ok(())
}

/// Move the free end of the selection.
#[frb(sync)]
pub fn terminal_select_update(
    id: u32,
    col: u16,
    line: i32,
    side_right: bool,
) -> Result<(), String> {
    let entry = entry(id)?;
    entry.session.select_update(col, line, side_right, |f| {
        entry.emit(TerminalEvent::frame(f.into()))
    });
    Ok(())
}

#[frb(sync)]
pub fn terminal_select_clear(id: u32) -> Result<(), String> {
    let entry = entry(id)?;
    entry
        .session
        .select_clear(|f| entry.emit(TerminalEvent::frame(f.into())));
    Ok(())
}

/// The selected text, or `None` when nothing is selected.
#[frb(sync)]
pub fn terminal_selection_text(id: u32) -> Result<Option<String>, String> {
    Ok(entry(id)?.session.selection_text())
}

/// Ask for a complete frame, for example after the view was recreated.
#[frb(sync)]
pub fn terminal_refresh(id: u32) -> Result<(), String> {
    let entry = entry(id)?;
    entry
        .session
        .full_frame(|f| entry.emit(TerminalEvent::frame(f.into())));
    Ok(())
}

/// The screen as plain text, for thumbnails and tests.
#[frb(sync)]
pub fn terminal_screen_text(id: u32) -> Result<String, String> {
    Ok(entry(id)?.session.screen_text())
}

/// Stop the program and forget the session.
#[frb(sync)]
pub fn terminal_close(id: u32) -> Result<(), String> {
    let removed = SESSIONS.lock().unwrap().remove(&id);
    if let Some(entry) = removed {
        entry.session.close();
        *entry.sink.lock().unwrap() = None;
    }
    Ok(())
}

#[frb(sync)]
pub fn terminal_list() -> Vec<SessionInfo> {
    let sessions = SESSIONS.lock().unwrap();
    let mut out: Vec<SessionInfo> = sessions
        .iter()
        .map(|(id, e)| {
            let exited = e.session.exited();
            SessionInfo {
                id: *id,
                label: match e.session.kind() {
                    SessionKind::LocalShell { program } => program.clone(),
                    SessionKind::Ssh { host } => host.clone(),
                },
                is_local: matches!(e.session.kind(), SessionKind::LocalShell { .. }),
                exited: exited.is_some(),
                exit_code: exited.flatten(),
            }
        })
        .collect();
    out.sort_by_key(|s| s.id);
    out
}
