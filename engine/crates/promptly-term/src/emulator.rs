//! The emulator: bytes in, frames out.

use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionRange, SelectionType};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{self, Processor};

use crate::frame::{self, CursorShape, CursorState, Frame, RowUpdate};
use crate::palette::{dim, pack, unpack, Palette, Rgb};
use crate::TermSize;

/// Things the program running in the terminal asked for that the session or
/// the UI must act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmulatorEvent {
    /// The terminal wants these bytes written back to the program (replies to
    /// queries such as cursor position or colour requests).
    PtyWrite(Vec<u8>),
    Title(Option<String>),
    Bell,
    /// OSC 52: the program asked to put this text on the clipboard.
    ClipboardStore(String),
    /// The program asked the terminal to exit.
    Exit,
}

/// How a selection grows from its anchor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectKind {
    /// Cell by cell, the usual drag.
    Simple,
    /// Whole words, a double click.
    Word,
    /// Whole lines, a triple click.
    Line,
    /// A rectangle, for columns of text.
    Block,
}

fn side(right: bool) -> Side {
    if right {
        Side::Right
    } else {
        Side::Left
    }
}

#[derive(Clone, Default)]
struct Listener(Arc<Mutex<Vec<Event>>>);

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        self.0.lock().unwrap().push(event);
    }
}

pub struct Emulator {
    term: Term<Listener>,
    parser: Processor,
    events: Listener,
    palette: Palette,
    size: TermSize,
    title: Option<String>,
    bell: bool,
    /// Set after a palette change or resize so the next frame is complete.
    force_full: bool,
    /// The selection as of the last frame, so rows it left are repainted.
    last_selection: Option<SelectionRange>,
}

impl Emulator {
    pub fn new(size: TermSize, palette: Palette) -> Self {
        let events = Listener::default();
        let config = Config {
            scrolling_history: 10_000,
            ..Config::default()
        };
        let term = Term::new(config, &size, events.clone());
        Self {
            term,
            parser: Processor::new(),
            events,
            palette,
            size,
            title: None,
            bell: false,
            force_full: true,
            last_selection: None,
        }
    }

    /// A viewport position as a grid point, clamped to cells that exist.
    /// `line` 0 is the top of the viewport; it may be negative or past the
    /// bottom while the pointer is dragged outside the terminal.
    fn point_at(&self, col: u16, line: i32) -> Point {
        let grid = self.term.grid();
        let line = Line(line - grid.display_offset() as i32)
            .clamp(self.term.topmost_line(), self.term.bottommost_line());
        let col = Column((col as usize).min(self.term.columns().saturating_sub(1)));
        Point::new(line, col)
    }

    /// Start a selection at a viewport cell. `side_right` is true when the
    /// pointer is in the right half of the cell.
    pub fn select_begin(&mut self, col: u16, line: i32, side_right: bool, kind: SelectKind) {
        let point = self.point_at(col, line);
        let ty = match kind {
            SelectKind::Simple => SelectionType::Simple,
            SelectKind::Word => SelectionType::Semantic,
            SelectKind::Line => SelectionType::Lines,
            SelectKind::Block => SelectionType::Block,
        };
        self.term.selection = Some(Selection::new(ty, point, side(side_right)));
    }

    /// Move the free end of the selection.
    pub fn select_update(&mut self, col: u16, line: i32, side_right: bool) {
        let point = self.point_at(col, line);
        if let Some(sel) = self.term.selection.as_mut() {
            sel.update(point, side(side_right));
        }
    }

    pub fn select_clear(&mut self) {
        self.term.selection = None;
    }

    /// The selected text, with trailing blanks trimmed and lines joined by
    /// newlines, or `None` when nothing is selected.
    pub fn selection_text(&self) -> Option<String> {
        self.term.selection_to_string()
    }

    pub fn size(&self) -> TermSize {
        self.size
    }

    pub fn palette(&self) -> &Palette {
        &self.palette
    }

    pub fn set_palette(&mut self, palette: Palette) {
        self.palette = palette;
        self.force_full = true;
    }

    /// Make the next frame complete, whatever changed.
    pub fn invalidate(&mut self) {
        self.force_full = true;
    }

    /// Feed bytes from the program. Returns what the program asked for.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<EmulatorEvent> {
        self.parser.advance(&mut self.term, bytes);
        self.drain_events()
    }

    pub fn resize(&mut self, size: TermSize) {
        if size == self.size {
            return;
        }
        self.size = size;
        self.term.resize(size);
        self.force_full = true;
    }

    /// Scroll the viewport: positive is up into history, negative back down.
    pub fn scroll(&mut self, delta: i32) {
        self.term.scroll_display(Scroll::Delta(delta));
    }

    pub fn scroll_to_bottom(&mut self) {
        self.term.scroll_display(Scroll::Bottom);
    }

    pub fn scroll_page(&mut self, up: bool) {
        self.term
            .scroll_display(if up { Scroll::PageUp } else { Scroll::PageDown });
    }

    /// True when arrow keys should send SS3 sequences.
    pub fn app_cursor(&self) -> bool {
        self.term.mode().contains(TermMode::APP_CURSOR)
    }

    pub fn bracketed_paste(&self) -> bool {
        self.term.mode().contains(TermMode::BRACKETED_PASTE)
    }

    /// Build the next frame: every row if something invalidated the whole
    /// screen, otherwise only the rows that changed since the last call.
    pub fn frame(&mut self) -> Frame {
        let display_offset = self.term.grid().display_offset();
        let screen_lines = self.term.screen_lines();

        let full = self.force_full || matches!(self.term.damage(), TermDamage::Full);
        let mut lines: Vec<usize> = if full {
            (0..screen_lines).collect()
        } else {
            let mut lines: Vec<usize> = match self.term.damage() {
                TermDamage::Full => (0..screen_lines).collect(),
                TermDamage::Partial(iter) => iter.map(|b| b.line).collect(),
            };
            lines.sort_unstable();
            lines.dedup();
            lines
        };
        self.term.reset_damage();
        self.force_full = false;

        let (cursor, mode, selection) = {
            let content = self.term.renderable_content();
            let cursor = CursorState {
                line: content.cursor.point.line.0 + display_offset as i32,
                col: content.cursor.point.column.0 as u16,
                shape: match content.cursor.shape {
                    ansi::CursorShape::Block => CursorShape::Block,
                    ansi::CursorShape::Underline => CursorShape::Underline,
                    ansi::CursorShape::Beam => CursorShape::Beam,
                    ansi::CursorShape::HollowBlock => CursorShape::HollowBlock,
                    ansi::CursorShape::Hidden => CursorShape::Hidden,
                },
            };
            (cursor, content.mode, content.selection)
        };

        // Rows the selection covered or now covers must be repainted too.
        if selection != self.last_selection {
            if !full {
                for range in [self.last_selection, selection].into_iter().flatten() {
                    let first = range.start.line.0 + display_offset as i32;
                    let last = range.end.line.0 + display_offset as i32;
                    for l in first.max(0)..=last.min(screen_lines as i32 - 1) {
                        lines.push(l as usize);
                    }
                }
                lines.sort_unstable();
                lines.dedup();
            }
            self.last_selection = selection;
        }

        let rows_changed = lines
            .into_iter()
            .filter(|l| *l < screen_lines)
            .map(|l| self.row_update(l, display_offset, selection.as_ref()))
            .collect();

        let bell = std::mem::take(&mut self.bell);
        Frame {
            cols: self.size.cols,
            rows: self.size.rows,
            full,
            rows_changed,
            cursor,
            display_offset: display_offset as u32,
            history_len: self.term.history_size() as u32,
            default_fg: self.palette.foreground,
            default_bg: self.palette.background,
            cursor_color: self.palette.cursor,
            title: self.title.clone(),
            bell,
            app_cursor: mode.contains(TermMode::APP_CURSOR),
            alt_screen: mode.contains(TermMode::ALT_SCREEN),
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
            mouse_reporting: mode.intersects(TermMode::MOUSE_MODE),
        }
    }

    fn row_update(
        &self,
        viewport_line: usize,
        display_offset: usize,
        selection: Option<&alacritty_terminal::selection::SelectionRange>,
    ) -> RowUpdate {
        let grid = self.term.grid();
        let overrides = self.term.colors();
        let line = Line(viewport_line as i32 - display_offset as i32);
        let row = &grid[line];
        let cols = grid.columns();

        let mut glyphs = Vec::with_capacity(cols);
        let mut fg = Vec::with_capacity(cols);
        let mut bg = Vec::with_capacity(cols);
        let mut flags_out = Vec::with_capacity(cols);

        for col in 0..cols {
            let cell = &row[Column(col)];
            let cf = cell.flags;

            let mut text = String::new();
            if cf.contains(Flags::WIDE_CHAR_SPACER) || cf.contains(Flags::LEADING_WIDE_CHAR_SPACER)
            {
                // Drawn as part of the wide character before it.
            } else if cell.c != ' ' || cell.zerowidth().is_some() {
                text.push(cell.c);
                if let Some(zw) = cell.zerowidth() {
                    text.extend(zw.iter());
                }
            }

            let mut f: Rgb = self.palette.resolve(cell.fg, overrides, cf, true);
            let mut b: Rgb = self.palette.resolve(cell.bg, overrides, cf, false);
            if cf.contains(Flags::DIM) {
                f = dim(f);
            }
            if cf.contains(Flags::INVERSE) {
                std::mem::swap(&mut f, &mut b);
            }
            if cf.contains(Flags::HIDDEN) {
                f = b;
            }

            let mut out = 0u16;
            if cf.contains(Flags::BOLD) {
                out |= frame::flags::BOLD;
            }
            if cf.contains(Flags::ITALIC) {
                out |= frame::flags::ITALIC;
            }
            if cf.contains(Flags::UNDERLINE) {
                out |= frame::flags::UNDERLINE;
            }
            if cf.contains(Flags::DOUBLE_UNDERLINE) {
                out |= frame::flags::DOUBLE_UNDERLINE;
            }
            if cf.contains(Flags::UNDERCURL) {
                out |= frame::flags::UNDERCURL;
            }
            if cf.contains(Flags::DOTTED_UNDERLINE) {
                out |= frame::flags::DOTTED_UNDERLINE;
            }
            if cf.contains(Flags::DASHED_UNDERLINE) {
                out |= frame::flags::DASHED_UNDERLINE;
            }
            if cf.contains(Flags::STRIKEOUT) {
                out |= frame::flags::STRIKEOUT;
            }
            if cf.contains(Flags::DIM) {
                out |= frame::flags::DIM;
            }
            if cf.contains(Flags::WIDE_CHAR) {
                out |= frame::flags::WIDE;
            }
            if cf.contains(Flags::WIDE_CHAR_SPACER) || cf.contains(Flags::LEADING_WIDE_CHAR_SPACER)
            {
                out |= frame::flags::WIDE_SPACER;
            }
            if let Some(sel) = selection {
                if sel.contains(Point::new(line, Column(col))) {
                    out |= frame::flags::SELECTED;
                    b = self.palette.selection;
                }
            }

            glyphs.push(text);
            fg.push(f);
            bg.push(b);
            flags_out.push(out);
        }

        RowUpdate {
            line: viewport_line as u16,
            glyphs,
            fg,
            bg,
            flags: flags_out,
        }
    }

    fn drain_events(&mut self) -> Vec<EmulatorEvent> {
        let events: Vec<Event> = std::mem::take(&mut *self.events.0.lock().unwrap());
        let mut out = Vec::new();
        let mut pty = Vec::new();
        for event in events {
            match event {
                Event::PtyWrite(s) => pty.extend_from_slice(s.as_bytes()),
                Event::Title(t) => {
                    self.title = Some(t.clone());
                    out.push(EmulatorEvent::Title(Some(t)));
                }
                Event::ResetTitle => {
                    self.title = None;
                    out.push(EmulatorEvent::Title(None));
                }
                Event::Bell => {
                    self.bell = true;
                    out.push(EmulatorEvent::Bell);
                }
                Event::ClipboardStore(_, text) => out.push(EmulatorEvent::ClipboardStore(text)),
                Event::ClipboardLoad(_, _) => {
                    // Reading the clipboard from a program is a security decision; off.
                }
                Event::ColorRequest(index, format) => {
                    let color = match index {
                        0..=255 => self.palette.indexed(index as u8),
                        256 => self.palette.foreground,
                        257 => self.palette.background,
                        258 => self.palette.cursor,
                        _ => self.palette.foreground,
                    };
                    let color = self.term.colors()[index].map(pack).unwrap_or(color);
                    pty.extend_from_slice(format(unpack(color)).as_bytes());
                }
                Event::TextAreaSizeRequest(format) => {
                    let size = WindowSize {
                        num_lines: self.size.rows,
                        num_cols: self.size.cols,
                        cell_width: 0,
                        cell_height: 0,
                    };
                    pty.extend_from_slice(format(size).as_bytes());
                }
                Event::Exit => out.push(EmulatorEvent::Exit),
                Event::ChildExit(_)
                | Event::Wakeup
                | Event::MouseCursorDirty
                | Event::CursorBlinkingChange => {}
            }
        }
        if !pty.is_empty() {
            out.insert(0, EmulatorEvent::PtyWrite(pty));
        }
        out
    }

    /// Plain text of the visible screen, for tests and thumbnails.
    pub fn screen_text(&self) -> String {
        let grid = self.term.grid();
        let display_offset = grid.display_offset();
        let mut s = String::new();
        for l in 0..grid.screen_lines() {
            let row = &grid[Line(l as i32 - display_offset as i32)];
            let mut line = String::new();
            for c in 0..grid.columns() {
                let cell = &row[Column(c)];
                if !cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
                    line.push(cell.c);
                }
            }
            s.push_str(line.trim_end());
            s.push('\n');
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn emu() -> Emulator {
        Emulator::new(TermSize::new(20, 4), Palette::promptly_dark())
    }

    #[test]
    fn text_lands_in_the_grid() {
        let mut e = emu();
        e.feed(b"hello\r\nworld");
        assert_eq!(e.screen_text(), "hello\nworld\n\n\n");
        let f = e.frame();
        assert!(f.full, "the first frame is complete");
        assert_eq!(f.rows_changed.len(), 4);
        assert_eq!(f.rows_changed[0].glyphs[0], "h");
        assert_eq!(
            f.rows_changed[0].glyphs[5], "",
            "blank cells carry no glyph"
        );
        assert_eq!(f.cursor.line, 1);
        assert_eq!(f.cursor.col, 5);
    }

    #[test]
    fn partial_frames_only_carry_changed_rows() {
        let mut e = emu();
        e.feed(b"one\r\ntwo\r\nthree");
        let _ = e.frame();
        e.feed(b"\x1b[1;1Hxyz");
        let f = e.frame();
        assert!(!f.full);
        let lines: Vec<u16> = f.rows_changed.iter().map(|r| r.line).collect();
        assert!(lines.contains(&0), "edited row is reported: {lines:?}");
        assert!(
            lines.contains(&2),
            "the row the cursor left is reported: {lines:?}"
        );
        assert!(
            !lines.contains(&1),
            "untouched row is not reported: {lines:?}"
        );
    }

    #[test]
    fn colours_and_styles_resolve() {
        let mut e = emu();
        e.feed(b"\x1b[1;31mR\x1b[0m \x1b[7mI\x1b[0m \x1b[38;2;1;2;3mT");
        let f = e.frame();
        let r = &f.rows_changed[0];
        assert_eq!(r.fg[0], Palette::promptly_dark().ansi[1]);
        assert_ne!(r.flags[0] & frame::flags::BOLD, 0);
        assert_eq!(
            r.fg[2],
            Palette::promptly_dark().background,
            "inverse swaps"
        );
        assert_eq!(r.bg[2], Palette::promptly_dark().foreground);
        assert_eq!(r.fg[4], 0x010203, "truecolor passes through");
    }

    #[test]
    fn queries_are_answered_back_to_the_program() {
        let mut e = emu();
        let events = e.feed(b"\x1b[6n");
        assert!(matches!(&events[0], EmulatorEvent::PtyWrite(b) if b == b"\x1b[1;1R"));
    }

    #[test]
    fn title_and_bell_are_reported() {
        let mut e = emu();
        let events = e.feed(b"\x1b]0;hello\x07\x07");
        assert!(events.contains(&EmulatorEvent::Title(Some("hello".into()))));
        assert!(events.contains(&EmulatorEvent::Bell));
        let f = e.frame();
        assert_eq!(f.title.as_deref(), Some("hello"));
        assert!(f.bell);
        assert!(!e.frame().bell, "bell is reported once");
    }

    #[test]
    fn scrollback_and_resize() {
        let mut e = emu();
        for i in 0..10 {
            e.feed(format!("line {i}\r\n").as_bytes());
        }
        let f = e.frame();
        assert!(f.history_len > 0);
        e.scroll(3);
        let f = e.frame();
        assert_eq!(f.display_offset, 3);
        assert!(f.full, "scrolling repaints everything");
        e.resize(TermSize::new(30, 6));
        let f = e.frame();
        assert_eq!((f.cols, f.rows), (30, 6));
        assert_eq!(f.rows_changed.len(), 6);
    }

    #[test]
    fn alternate_screen_restores_the_primary_screen() {
        let mut e = emu();
        e.feed(b"primary");
        e.feed(b"\x1b[?1049h\x1b[2Jalt screen");
        assert!(e.frame().alt_screen);
        assert!(e.screen_text().contains("alt screen"));
        assert!(!e.screen_text().contains("primary"));
        e.feed(b"\x1b[?1049l");
        let f = e.frame();
        assert!(!f.alt_screen);
        assert!(f.full, "leaving the alternate screen repaints everything");
        assert!(e.screen_text().starts_with("primary"));
    }

    #[test]
    fn selection_marks_cells_and_reads_back_as_text() {
        let mut e = emu();
        e.feed(b"hello world\r\nsecond line");
        let _ = e.frame();
        e.select_begin(0, 0, false, SelectKind::Simple);
        e.select_update(4, 0, true);
        let f = e.frame();
        assert!(!f.full);
        // The selected row is resent (so is the cursor's row, which the
        // emulator always reports); untouched rows are not.
        let lines: Vec<u16> = f.rows_changed.iter().map(|r| r.line).collect();
        assert!(lines.contains(&0), "selected row is resent: {lines:?}");
        assert!(!lines.contains(&2), "untouched row is not: {lines:?}");
        let r = f.rows_changed.iter().find(|r| r.line == 0).unwrap();
        assert_ne!(r.flags[0] & frame::flags::SELECTED, 0);
        assert_eq!(r.bg[0], Palette::promptly_dark().selection);
        assert_eq!(r.flags[5] & frame::flags::SELECTED, 0);
        assert_eq!(e.selection_text().as_deref(), Some("hello"));

        // Extend onto the next line: both rows are resent.
        e.select_update(5, 1, true);
        let f = e.frame();
        let lines: Vec<u16> = f.rows_changed.iter().map(|r| r.line).collect();
        assert_eq!(lines, vec![0, 1]);
        assert_eq!(e.selection_text().as_deref(), Some("hello world\nsecond"));

        e.select_clear();
        let f = e.frame();
        let lines: Vec<u16> = f.rows_changed.iter().map(|r| r.line).collect();
        assert_eq!(lines, vec![0, 1], "rows the selection left are resent");
        assert_eq!(f.rows_changed[0].flags[0] & frame::flags::SELECTED, 0);
        assert!(e.selection_text().is_none());
    }

    #[test]
    fn word_and_line_selection_and_out_of_range_points() {
        let mut e = emu();
        e.feed(b"cd /srv/app && ls\r\nnext");
        e.select_begin(5, 0, false, SelectKind::Word);
        assert_eq!(e.selection_text().as_deref(), Some("/srv/app"));
        // Whole lines end with a newline, so pasting them runs them.
        e.select_begin(3, 0, false, SelectKind::Line);
        assert_eq!(e.selection_text().as_deref(), Some("cd /srv/app && ls\n"));
        // Dragging far outside the viewport clamps to the last row, so the
        // two blank rows under "next" come along.
        e.select_update(999, 99, true);
        assert_eq!(
            e.selection_text().as_deref(),
            Some("cd /srv/app && ls\nnext\n\n\n")
        );
    }

    #[test]
    fn wide_characters_take_two_cells() {
        let mut e = emu();
        e.feed("日本".as_bytes());
        let f = e.frame();
        let r = &f.rows_changed[0];
        assert_eq!(r.glyphs[0], "日");
        assert_ne!(r.flags[0] & frame::flags::WIDE, 0);
        assert_eq!(r.glyphs[1], "");
        assert_ne!(r.flags[1] & frame::flags::WIDE_SPACER, 0);
        assert_eq!(r.glyphs[2], "本");
    }
}
