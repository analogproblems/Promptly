//! Terminal sessions for the app: open, write, resize, scroll, close, and a
//! stream of frames to paint.
//!
//! Sessions live in a registry keyed by a small integer id so the Dart side
//! holds nothing but the id. Frames are built under the session's lock and
//! handed to the stream in order.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;
use promptly_session::{pump, LocalShell, Session, SessionEvent, SessionKind, Transport};
use promptly_term::{
    CursorShape, Frame, Palette, SelectKind, TermSize, DEFAULT_SCROLLBACK, MAX_SCROLLBACK,
};

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

/// Lines of history new sessions keep; see [`terminal_set_scrollback`].
static SCROLLBACK: AtomicUsize = AtomicUsize::new(DEFAULT_SCROLLBACK);

/// How many lines of history a session opened now should keep.
pub(crate) fn scrollback() -> usize {
    SCROLLBACK.load(Ordering::Relaxed)
}

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
    /// Underline colour per column: the program's own, or the text colour.
    pub underline: Vec<u32>,
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

/// Where the focused search match is, for "3 of 12" in the search bar.
pub struct TerminalSearchHit {
    pub index: u32,
    pub total: u32,
    /// Viewport row of the match, after scrolling it into view.
    pub line: i32,
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
                    underline: r.underline,
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

/// The palette for a theme id, built in or imported.
pub(crate) fn palette_for(theme: &str) -> Palette {
    crate::api::themes::palette_for(theme)
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

pub(crate) fn session_exists(id: u32) -> bool {
    SESSIONS.lock().unwrap().contains_key(&id)
}

/// Give an existing session a new transport, for reconnecting without
/// losing the screen. Frames resume on the session's existing stream.
pub(crate) fn reattach_session(
    id: u32,
    transport: Box<dyn Transport>,
    reader: Box<dyn std::io::Read + Send>,
) -> Result<(), String> {
    let entry = entry(id)?;
    entry.session.replace_transport(transport);
    if entry.sink.lock().unwrap().is_some() {
        let emitter = entry.clone();
        pump(entry.session.clone(), reader, move |event| {
            emitter.emit(event.into())
        });
    } else {
        *entry.reader.lock().unwrap() = Some(reader);
    }
    Ok(())
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
    let session = Arc::new(Session::with_scrollback(
        kind,
        size,
        palette_for(&theme),
        Box::new(shell),
        scrollback(),
    ));
    Ok(register_session(session, reader))
}

/// How many lines of history sessions opened from now on keep, up to
/// 100,000. Sessions already open keep what they started with.
#[frb(sync)]
pub fn terminal_set_scrollback(lines: u32) {
    let lines = (lines as usize).clamp(1, MAX_SCROLLBACK);
    SCROLLBACK.store(lines, Ordering::Relaxed);
}

/// Subscribe to a session's frames. Starts the read loop on first call.
pub fn terminal_events(id: u32, sink: StreamSink<TerminalEvent>) -> anyhow::Result<()> {
    let entry = entry(id).map_err(anyhow::Error::msg)?;
    // The UI has the session now, so a late cancel of its connect can't close it.
    crate::ssh_flow::claim_session(id);
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

/// What the mouse did, for [`terminal_mouse`].
pub enum TerminalMouseAction {
    Press,
    Release,
    /// Moved, with `button` held or none.
    Move,
    WheelUp,
    WheelDown,
}

pub enum TerminalMouseButton {
    Left,
    Middle,
    Right,
}

/// Send a mouse event to the program at a zero-based screen cell, if it
/// asked for mouse events of that kind (vim with `mouse=a`, tmux). Returns
/// false when it did not, so the view selects or scrolls as usual.
#[frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn terminal_mouse(
    id: u32,
    action: TerminalMouseAction,
    button: Option<TerminalMouseButton>,
    col: u16,
    row: u16,
    shift: bool,
    alt: bool,
    ctrl: bool,
) -> Result<bool, String> {
    use promptly_term::{MouseAction, MouseButton, MouseEvent};
    let button = button.map(|b| match b {
        TerminalMouseButton::Left => MouseButton::Left,
        TerminalMouseButton::Middle => MouseButton::Middle,
        TerminalMouseButton::Right => MouseButton::Right,
    });
    let pressed = button.unwrap_or(MouseButton::Left);
    let action = match action {
        TerminalMouseAction::Press => MouseAction::Press(pressed),
        TerminalMouseAction::Release => MouseAction::Release(pressed),
        TerminalMouseAction::Move => MouseAction::Move(button),
        TerminalMouseAction::WheelUp => MouseAction::WheelUp,
        TerminalMouseAction::WheelDown => MouseAction::WheelDown,
    };
    entry(id)?
        .session
        .mouse(MouseEvent {
            action,
            col,
            row,
            shift,
            alt,
            ctrl,
        })
        .map_err(|e| e.to_string())
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

/// Search the screen and scrollback for `query` (plain text, any case), or
/// stop searching with `None`. Matches are highlighted in the frames.
#[frb(sync)]
pub fn terminal_search_set(id: u32, query: Option<String>) -> Result<(), String> {
    let entry = entry(id)?;
    entry.session.search_set(query.as_deref(), |f| {
        entry.emit(TerminalEvent::frame(f.into()))
    });
    Ok(())
}

/// Move to the next match: up into history when `backward`. The match is
/// selected and scrolled into view. `None` when nothing matches.
#[frb(sync)]
pub fn terminal_search_step(id: u32, backward: bool) -> Result<Option<TerminalSearchHit>, String> {
    let entry = entry(id)?;
    let hit = entry
        .session
        .search_step(backward, |f| entry.emit(TerminalEvent::frame(f.into())));
    Ok(hit.map(|h| TerminalSearchHit {
        index: h.index,
        total: h.total,
        line: h.line,
    }))
}

/// A link under a cell.
pub struct TerminalLink {
    pub uri: String,
    /// An OSC 8 hyperlink whose text on screen is not its address: where
    /// it goes is shown before it opens.
    pub hidden: bool,
}

/// The link under a viewport cell: an OSC 8 hyperlink, or a URL, file path
/// or IP address in the text. Only a URL contains `://`.
#[frb(sync)]
pub fn terminal_link_at(id: u32, col: u16, line: i32) -> Result<Option<TerminalLink>, String> {
    Ok(entry(id)?.session.link_at(col, line).map(|l| TerminalLink {
        uri: l.uri,
        hidden: l.hidden,
    }))
}

/// Show a message from Promptly in the terminal, such as "connection
/// dropped". Use `\r\n` for line breaks; nothing is sent to the program.
#[frb(sync)]
pub fn terminal_notice(id: u32, text: String) -> Result<(), String> {
    let entry = entry(id)?;
    entry
        .session
        .notice(&text, |f| entry.emit(TerminalEvent::frame(f.into())));
    Ok(())
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
    crate::ssh_flow::forget_connection(id);
    crate::ssh_flow::claim_session(id);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrollback_for_new_sessions_stays_in_range() {
        terminal_set_scrollback(0);
        assert_eq!(scrollback(), 1);
        terminal_set_scrollback(5_000_000);
        assert_eq!(scrollback(), MAX_SCROLLBACK);
        terminal_set_scrollback(50_000);
        assert_eq!(scrollback(), 50_000);
        terminal_set_scrollback(DEFAULT_SCROLLBACK as u32);
    }

    #[test]
    fn frames_carry_underline_colours() {
        let mut e = promptly_term::Emulator::new(TermSize::new(4, 1), Palette::promptly_dark());
        e.feed(b"\x1b[4:3;58;2;1;2;3mx");
        let frame: TerminalFrame = e.frame().into();
        assert_eq!(frame.rows_changed[0].underline[0], 0x010203);
    }
}
