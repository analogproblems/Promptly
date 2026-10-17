//! The emulator: bytes in, frames out.

use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Direction, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionRange, SelectionType};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::search::{Match, RegexIter, RegexSearch};
use alacritty_terminal::term::{Config, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{self, Processor};
use std::sync::LazyLock;

use crate::frame::{self, CursorShape, CursorState, Frame, RowUpdate};
use crate::palette::{dim, mix, pack, unpack, Palette, Rgb};
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

/// Where the focused search match sits, for the "3 of 12" in the search
/// bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchHit {
    /// 1-based position of the focused match among all matches, oldest
    /// first.
    pub index: u32,
    pub total: u32,
    /// Viewport row of the focused match after scrolling it into view.
    pub line: i32,
}

/// An active search: the compiled query, and the match the person is on.
struct Search {
    grid: RegexSearch,
    row: regex::Regex,
    focus: Option<Match>,
}

/// Plain-text URLs worth a click. Trailing punctuation is trimmed when the
/// link is read back.
static URL: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r#"(?i)\b(?:https?|ftp|ssh|git|file)://[^\s<>"'`]+"#).expect("url regex")
});

const MAX_MATCHES: usize = 10_000;

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
    search: Option<Search>,
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
            search: None,
        }
    }

    // ---- Search ------------------------------------------------------------

    /// Start searching for `query` (case-insensitive, plain text), or stop
    /// with `None`. Every match is highlighted from the next frame on;
    /// `search_step` moves between them.
    pub fn search_set(&mut self, query: Option<&str>) {
        let query = query.map(str::trim).filter(|q| !q.is_empty());
        let had_focus = self.search.as_ref().is_some_and(|s| s.focus.is_some());
        self.search = query.and_then(|q| {
            let pattern = format!("(?i){}", regex::escape(q));
            Some(Search {
                grid: RegexSearch::new(&pattern).ok()?,
                row: regex::Regex::new(&pattern).ok()?,
                focus: None,
            })
        });
        if had_focus {
            // The old focus was shown as the selection; it no longer applies.
            self.term.selection = None;
        }
        self.force_full = true;
    }

    /// Move to the next match: up into history when `backward`, else down
    /// towards the newest output. Starts from the bottom of the viewport.
    /// The match becomes the selection and is scrolled into view.
    ///
    /// Steps through the same list of matches that is counted, so the
    /// focus is always one of the highlighted matches. (Searching backwards
    /// cell by cell can land on an overlapping match instead, such as the
    /// second "22" inside "222".)
    pub fn search_step(&mut self, backward: bool) -> Option<SearchHit> {
        let matches = self.matches();
        let search = self.search.as_mut()?;
        if matches.is_empty() {
            search.focus = None;
            return None;
        }
        let at = match &search.focus {
            Some(m) => *m.start(),
            None => {
                let display_offset = self.term.grid().display_offset() as i32;
                if backward {
                    let bottom = Line(self.term.screen_lines() as i32 - 1 - display_offset);
                    Point::new(bottom, self.term.last_column())
                } else {
                    Point::new(Line(-display_offset), Column(0))
                }
            }
        };
        // Without a focus the match at `at` itself counts; with one, it is
        // the match being left.
        let include_at = search.focus.is_none();
        let n = matches.len();
        let i = if backward {
            let before =
                matches.partition_point(|m| *m.start() < at || (include_at && *m.start() == at));
            before.checked_sub(1).unwrap_or(n - 1)
        } else {
            let after =
                matches.partition_point(|m| *m.start() < at || (!include_at && *m.start() == at));
            if after == n {
                0
            } else {
                after
            }
        };
        let found = matches[i].clone();
        search.focus = Some(found.clone());

        let mut selection = Selection::new(SelectionType::Simple, *found.start(), Side::Left);
        selection.update(*found.end(), Side::Right);
        self.term.selection = Some(selection);

        // Bring the match into view, centred when it was off screen.
        let display_offset = self.term.grid().display_offset() as i32;
        let screen = self.term.screen_lines() as i32;
        let line = found.start().line.0;
        let visible = line >= -display_offset && line < screen - display_offset;
        let mut offset = display_offset;
        if !visible {
            offset = (screen / 2 - line).clamp(0, self.term.history_size() as i32);
            self.term
                .scroll_display(Scroll::Delta(offset - display_offset));
        }
        self.force_full = true;

        Some(SearchHit {
            index: i as u32 + 1,
            total: n as u32,
            line: line + offset,
        })
    }

    /// Every match in the grid, oldest first.
    fn matches(&mut self) -> Vec<Match> {
        let Some(search) = self.search.as_mut() else {
            return Vec::new();
        };
        let start = Point::new(self.term.topmost_line(), Column(0));
        let end = Point::new(self.term.bottommost_line(), self.term.last_column());
        RegexIter::new(start, end, Direction::Right, &self.term, &mut search.grid)
            .take(MAX_MATCHES)
            .collect()
    }

    // ---- Links -------------------------------------------------------------

    /// The link under a viewport cell: an OSC 8 hyperlink, or a URL written
    /// in the text of that row.
    pub fn link_at(&self, col: u16, line: i32) -> Option<String> {
        let point = self.point_at(col, line);
        let grid = self.term.grid();
        if let Some(link) = grid[point.line][point.column].hyperlink() {
            return Some(link.uri().to_string());
        }
        let (text, columns, _) = row_text(grid, point.line);
        for m in URL.find_iter(&text) {
            let cols = (columns[m.start()], columns[m.end().saturating_sub(1)]);
            if point.column.0 >= cols.0 && point.column.0 <= cols.1 {
                return Some(
                    m.as_str()
                        .trim_end_matches(['.', ',', ';', ':', ')', ']', '}', '\'', '"', '!', '?'])
                        .to_string(),
                );
            }
        }
        None
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

    /// The bytes that report a mouse event to the program, or `None` when
    /// it has not asked for mouse events of that kind.
    pub fn mouse_report(&self, event: crate::MouseEvent) -> Option<Vec<u8>> {
        crate::mouse::encode(*self.term.mode(), event)
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

        // Search matches and plain URLs are found on the row's text once.
        let (text, columns, wide) = row_text(grid, line);
        let mut marks = vec![0u16; cols];
        let focus = self.search.as_ref().and_then(|s| s.focus.as_ref());
        if let Some(search) = &self.search {
            for m in search.row.find_iter(&text) {
                mark(
                    &mut marks,
                    &columns,
                    &wide,
                    m.start(),
                    m.end(),
                    frame::flags::MATCH,
                );
            }
        }
        for m in URL.find_iter(&text) {
            mark(
                &mut marks,
                &columns,
                &wide,
                m.start(),
                m.end(),
                frame::flags::LINK,
            );
        }

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
            out |= marks[col];
            if cell.hyperlink().is_some() {
                out |= frame::flags::LINK;
            }
            // The match the search bar is on is solid yellow; the others
            // are a softer yellow so it stands out among them.
            let point = Point::new(line, Column(col));
            let focused = focus.is_some_and(|m| m.contains(&point));
            if focused {
                out |= frame::flags::MATCH;
                b = self.palette.ansi[3];
                f = self.palette.background;
            } else if out & frame::flags::MATCH != 0 {
                b = mix(self.palette.ansi[3], self.palette.background, 0.45);
                f = self.palette.foreground;
            }
            if let Some(sel) = selection {
                if sel.contains(point) {
                    out |= frame::flags::SELECTED;
                    // The focused match is also the selection (so Copy
                    // works); it keeps its highlight.
                    if !focused {
                        b = self.palette.selection;
                        if out & frame::flags::MATCH != 0 {
                            f = self.palette.foreground;
                        }
                    }
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

/// A grid row as text, with the column each byte of it came from and which
/// columns hold a double-width character.
fn row_text(
    grid: &alacritty_terminal::grid::Grid<alacritty_terminal::term::cell::Cell>,
    line: Line,
) -> (String, Vec<usize>, Vec<bool>) {
    let row = &grid[line];
    let mut text = String::with_capacity(grid.columns());
    let mut columns = Vec::with_capacity(grid.columns());
    let mut wide = vec![false; grid.columns()];
    for col in 0..grid.columns() {
        let cell = &row[Column(col)];
        if cell.flags.contains(Flags::WIDE_CHAR_SPACER)
            || cell.flags.contains(Flags::LEADING_WIDE_CHAR_SPACER)
        {
            continue;
        }
        wide[col] = cell.flags.contains(Flags::WIDE_CHAR);
        let before = text.len();
        text.push(cell.c);
        columns.extend(std::iter::repeat_n(col, text.len() - before));
    }
    (text, columns, wide)
}

/// Set `flag` on the columns that bytes `start..end` of the row text came
/// from, including the spacer after a wide character.
fn mark(marks: &mut [u16], columns: &[usize], wide: &[bool], start: usize, end: usize, flag: u16) {
    for &col in columns.iter().take(end.min(columns.len())).skip(start) {
        marks[col] |= flag;
        if wide[col] && col + 1 < marks.len() {
            marks[col + 1] |= flag;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn emu() -> Emulator {
        Emulator::new(TermSize::new(20, 4), Palette::promptly_dark())
    }

    #[test]
    fn search_highlights_steps_and_counts() {
        let mut e = emu();
        for i in 0..8 {
            e.feed(format!("line {i} needle\r\n").as_bytes());
        }
        e.feed(b"last NEEDLE here");
        let _ = e.frame();

        e.search_set(Some("needle"));
        let f = e.frame();
        assert!(f.full);
        let last = f.rows_changed.iter().find(|r| r.line == 3).unwrap();
        assert_ne!(
            last.flags[5] & frame::flags::MATCH,
            0,
            "matches ignore case"
        );
        assert_eq!(last.flags[4] & frame::flags::MATCH, 0);
        let p = Palette::promptly_dark();
        assert_eq!(last.bg[5], mix(p.ansi[3], p.background, 0.45));

        // Up from the bottom: the newest match first, then older ones,
        // scrolling into history when needed.
        let hit = e.search_step(true).unwrap();
        assert_eq!((hit.index, hit.total), (9, 9));
        assert_eq!(hit.line, 3);
        assert_eq!(e.selection_text().as_deref(), Some("NEEDLE"));
        let hit = e.search_step(true).unwrap();
        assert_eq!((hit.index, hit.total), (8, 9));
        for _ in 0..6 {
            e.search_step(true).unwrap();
        }
        let hit = e.search_step(true).unwrap();
        assert_eq!(hit.index, 1, "the oldest match");
        assert!(e.frame().display_offset > 0, "scrolled back to show it");
        // Past the first match wraps to the last.
        assert_eq!(e.search_step(true).unwrap().index, 9);
        // And forwards goes the other way.
        assert_eq!(e.search_step(false).unwrap().index, 1);

        e.search_set(None);
        let f = e.frame();
        assert!(f.full);
        assert!(
            e.selection_text().is_none(),
            "clearing the search drops its selection"
        );
        assert!(f
            .rows_changed
            .iter()
            .all(|r| r.flags.iter().all(|f| f & frame::flags::MATCH == 0)));
        assert!(e.search_step(true).is_none());
    }

    #[test]
    fn focused_match_is_one_of_the_counted_matches_and_stands_out() {
        // Typing "22" with "10.99.1.222" on screen: stepping back from the
        // bottom used to land on the overlapping second "22", which the
        // counter did not know ("0 of 1") and which was drawn half as a
        // match, half as a selection.
        let mut e = Emulator::new(TermSize::new(30, 3), Palette::promptly_dark());
        let p = Palette::promptly_dark();
        e.feed(b"addr 10.99.1.222");
        let _ = e.frame();

        e.search_set(Some("22"));
        let hit = e.search_step(true).unwrap();
        assert_eq!((hit.index, hit.total), (1, 1));
        assert_eq!(e.selection_text().as_deref(), Some("22"));
        let f = e.frame();
        let row = f.rows_changed.iter().find(|r| r.line == 0).unwrap();
        // "addr 10.99.1." is 13 columns; the match is columns 13 and 14.
        for col in [13, 14] {
            assert_eq!(row.bg[col], p.ansi[3], "column {col} is the focused match");
            assert_eq!(row.fg[col], p.background);
            assert_ne!(row.flags[col] & frame::flags::SELECTED, 0, "still copyable");
        }
        assert_eq!(row.flags[15] & frame::flags::MATCH, 0);
        assert_eq!(row.bg[15], p.background, "the last 2 is not part of it");

        // Typing one more character keeps the focus drawn as the focus, not
        // in the selection colour.
        e.search_set(Some("222"));
        let hit = e.search_step(true).unwrap();
        assert_eq!((hit.index, hit.total), (1, 1));
        let f = e.frame();
        let row = f.rows_changed.iter().find(|r| r.line == 0).unwrap();
        for col in 13..16 {
            assert_eq!(row.bg[col], p.ansi[3]);
        }

        // Other matches are softer than the focused one.
        e.search_set(Some("9"));
        e.search_step(true).unwrap();
        let f = e.frame();
        let row = f.rows_changed.iter().find(|r| r.line == 0).unwrap();
        assert_eq!(row.bg[9], p.ansi[3], "the newest 9 is focused");
        assert_eq!(row.bg[8], mix(p.ansi[3], p.background, 0.45));
        assert_eq!(row.flags[8] & frame::flags::SELECTED, 0);
    }

    #[test]
    fn links_are_flagged_and_read_back() {
        let mut e = Emulator::new(TermSize::new(60, 4), Palette::promptly_dark());
        e.feed(b"see https://example.com/docs, now\r\n");
        e.feed(b"\x1b]8;;https://hidden.example/x\x1b\\click me\x1b]8;;\x1b\\ plain");
        let f = e.frame();
        let first = &f.rows_changed[0];
        assert_eq!(first.flags[3] & frame::flags::LINK, 0);
        assert_ne!(first.flags[4] & frame::flags::LINK, 0);
        assert_ne!(
            first.flags[27] & frame::flags::LINK,
            0,
            "the comma is flagged with the url"
        );
        assert_eq!(first.flags[29] & frame::flags::LINK, 0);
        assert_eq!(
            e.link_at(10, 0).as_deref(),
            Some("https://example.com/docs"),
            "trailing punctuation is not part of the link"
        );
        assert_eq!(e.link_at(1, 0), None);

        let second = &f.rows_changed[1];
        assert_ne!(second.flags[0] & frame::flags::LINK, 0);
        assert_ne!(second.flags[7] & frame::flags::LINK, 0);
        assert_eq!(second.flags[9] & frame::flags::LINK, 0);
        assert_eq!(e.link_at(2, 1).as_deref(), Some("https://hidden.example/x"));
        assert_eq!(e.link_at(12, 1), None);
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
