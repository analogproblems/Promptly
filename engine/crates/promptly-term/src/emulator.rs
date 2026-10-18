//! The emulator: bytes in, frames out.

use std::sync::{Arc, Mutex};
use std::time::Instant;

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::{Dimensions, Row, Scroll};
use alacritty_terminal::index::{Column, Direction, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionRange, SelectionType};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::search::{RegexIter, RegexSearch};
use alacritty_terminal::term::{Config, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{self, Processor};

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

/// An active search: the compiled query, and whether the selection is the
/// match the person is on.
struct Search {
    grid: RegexSearch,
    row: regex::Regex,
    focused: bool,
}

/// Lines of scrollback a terminal keeps unless told otherwise.
pub const DEFAULT_SCROLLBACK: usize = 10_000;

/// The most scrollback a terminal may keep. Each line costs a row of cells,
/// so this bounds the memory one busy session can take.
pub const MAX_SCROLLBACK: usize = 100_000;

#[derive(Clone, Default)]
struct Listener(Arc<Mutex<Vec<Event>>>);

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        self.0.lock().unwrap().push(event);
    }
}

/// A link under a cell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub uri: String,
    /// An OSC 8 hyperlink whose text on screen is not its address, so
    /// where it goes must be shown before it is opened.
    pub hidden: bool,
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
        Self::with_scrollback(size, palette, DEFAULT_SCROLLBACK)
    }

    /// A terminal that keeps `lines` of history (at most [`MAX_SCROLLBACK`]).
    pub fn with_scrollback(size: TermSize, palette: Palette, lines: usize) -> Self {
        let events = Listener::default();
        let config = Config {
            scrolling_history: lines.min(MAX_SCROLLBACK),
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
        let had_focus = self.search.as_ref().is_some_and(|s| s.focused);
        self.search = query.and_then(|q| {
            let pattern = format!("(?i){}", regex::escape(q));
            Some(Search {
                grid: RegexSearch::new(&pattern).ok()?,
                row: regex::Regex::new(&pattern).ok()?,
                focused: false,
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
    /// Walks the matches in the same order they are counted, so the focus
    /// is always one of the highlighted matches. (Searching backwards cell
    /// by cell can land on an overlapping match instead, such as the
    /// second "22" inside "222".)
    pub fn search_step(&mut self, backward: bool) -> Option<SearchHit> {
        let search = self.search.as_mut()?;
        // The focus is the selection, which the terminal keeps on the same
        // text as output scrolls it.
        let focus = if search.focused {
            self.term
                .selection
                .as_ref()
                .and_then(|s| s.to_range(&self.term))
                .map(|r| r.start)
        } else {
            None
        };
        let at = focus.unwrap_or_else(|| {
            let display_offset = self.term.grid().display_offset() as i32;
            if backward {
                let bottom = Line(self.term.screen_lines() as i32 - 1 - display_offset);
                Point::new(bottom, self.term.last_column())
            } else {
                Point::new(Line(-display_offset), Column(0))
            }
        });
        // Without a focus the match at `at` itself counts; with one, it is
        // the match being left.
        let include_at = focus.is_none();

        // One pass over every match, oldest first: the count, the next
        // match each way, and the ends to wrap round to.
        let start = Point::new(self.term.topmost_line(), Column(0));
        let end = Point::new(self.term.bottommost_line(), self.term.last_column());
        let mut total = 0u32;
        let mut first = None;
        let mut last = None;
        let mut next = None;
        for m in RegexIter::new(start, end, Direction::Right, &self.term, &mut search.grid) {
            total += 1;
            let s = *m.start();
            let hit = if backward {
                s < at || (include_at && s == at)
            } else {
                next.is_none() && (s > at || (include_at && s == at))
            };
            if hit {
                next = Some((total, m.clone()));
            }
            if first.is_none() {
                first = Some(m.clone());
            }
            last = Some(m);
        }
        let (index, found) = match next {
            Some(n) => n,
            None if backward => (total, last?),
            None => (1, first?),
        };
        search.focused = true;

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
            index,
            total,
            line: line + offset,
        })
    }

    // ---- Links -------------------------------------------------------------

    /// The link under a viewport cell: an OSC 8 hyperlink, or a URL, file
    /// path or IP address written in the text of that row. Only a URL has
    /// `://` in it, which is how the UI tells what to do with one.
    pub fn link_at(&self, col: u16, line: i32) -> Option<Link> {
        let point = self.point_at(col, line);
        let grid = self.term.grid();
        let row = &grid[point.line];
        if let Some(link) = row[point.column].hyperlink() {
            // What it says on screen: the run of cells carrying this link.
            let same = |c: usize| row[Column(c)].hyperlink().as_ref() == Some(&link);
            let mut first = point.column.0;
            while first > 0 && same(first - 1) {
                first -= 1;
            }
            let mut last = point.column.0;
            while last + 1 < grid.columns() && same(last + 1) {
                last += 1;
            }
            let shown: String = (first..=last)
                .map(|c| &row[Column(c)])
                .filter(|cell| {
                    !cell.flags.contains(Flags::WIDE_CHAR_SPACER)
                        && !cell.flags.contains(Flags::LEADING_WIDE_CHAR_SPACER)
                })
                .map(|cell| cell.c)
                .collect();
            return Some(Link {
                hidden: shown.trim() != link.uri() || self.obscured(row, first, last),
                uri: link.uri().to_string(),
            });
        }
        let (text, columns, wide) = row_text(grid, point.line);
        for found in crate::links::find(&text) {
            let first = columns[found.start];
            let mut last = columns[found.end - 1];
            if wide[last] {
                last += 1;
            }
            if point.column.0 >= first && point.column.0 <= last {
                return Some(Link {
                    uri: text[found.start..found.end].to_string(),
                    hidden: self.obscured(row, first, last),
                });
            }
        }
        None
    }

    /// The colours a cell is drawn in: its text, then its background.
    fn cell_colors(&self, cell: &Cell, overrides: &Colors) -> (Rgb, Rgb) {
        let cf = cell.flags;
        let mut f = self.palette.resolve(cell.fg, overrides, cf, true);
        let mut b = self.palette.resolve(cell.bg, overrides, cf, false);
        if cf.contains(Flags::DIM) {
            f = dim(f);
        }
        if cf.contains(Flags::INVERSE) {
            std::mem::swap(&mut f, &mut b);
        }
        if cf.contains(Flags::HIDDEN) {
            f = b;
        }
        (f, b)
    }

    /// Whether any character from `first` to `last` can't be read: drawn
    /// in its background colour, or close to it, as concealed text is.
    /// Part of a link the user can't see could change where it goes, so
    /// such a link asks before it opens.
    fn obscured(&self, row: &Row<Cell>, first: usize, last: usize) -> bool {
        let overrides = self.term.colors();
        let near = |a: Rgb, b: Rgb| {
            (0..3).all(|i| ((a >> (8 * i)) & 0xFF).abs_diff((b >> (8 * i)) & 0xFF) < 32)
        };
        (first..=last).any(|c| {
            let cell = &row[Column(c)];
            let (f, b) = self.cell_colors(cell, overrides);
            cell.c != ' ' && near(f, b)
        })
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
        self.unfocus();
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
        self.unfocus();
    }

    /// The selection is no longer the search match: the person made or
    /// dropped one themselves.
    fn unfocus(&mut self) {
        if let Some(search) = self.search.as_mut() {
            if search.focused {
                search.focused = false;
                self.force_full = true;
            }
        }
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
        // A synchronized update that ran out of time ends before more
        // output lands, or the parser would go on holding everything back.
        if self.sync_deadline().is_some_and(|d| d <= Instant::now()) {
            self.parser.stop_sync(&mut self.term);
        }
        self.parser.advance(&mut self.term, bytes);
        self.drain_events()
    }

    /// When the synchronized update in progress is given up on, or `None`
    /// when there is none. Full-screen programs wrap a redraw in one (DEC
    /// mode 2026) so it lands in one go; until it ends, its output is held
    /// back.
    pub fn sync_deadline(&self) -> Option<Instant> {
        self.parser.sync_timeout().sync_timeout()
    }

    /// Show what a synchronized update has drawn so far if it is past its
    /// deadline (the program never said it was done), so the screen does
    /// not stay frozen. Returns what the held-back output asked for, or
    /// `None` when nothing was due.
    pub fn end_stalled_sync(&mut self, now: Instant) -> Option<Vec<EmulatorEvent>> {
        if !self.sync_deadline().is_some_and(|d| d <= now) {
            return None;
        }
        self.end_sync()
    }

    /// Show what a synchronized update has drawn so far, due or not, for
    /// when the program has ended and will never finish it. `None` when no
    /// update was in progress.
    pub fn end_sync(&mut self) -> Option<Vec<EmulatorEvent>> {
        self.sync_deadline()?;
        self.parser.stop_sync(&mut self.term);
        Some(self.drain_events())
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
        let mut underline = Vec::with_capacity(cols);

        // Search matches and plain links are found on the row's text once.
        let (text, columns, wide) = row_text(grid, line);
        let mut marks = vec![0u16; cols];
        let focused_sel = selection.filter(|_| self.search.as_ref().is_some_and(|s| s.focused));
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
        for found in crate::links::find(&text) {
            let flag = match found.kind {
                crate::links::LinkKind::Url => frame::flags::LINK,
                _ => frame::flags::PATH_OR_ADDRESS,
            };
            mark(&mut marks, &columns, &wide, found.start, found.end, flag);
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

            let (mut f, mut b) = self.cell_colors(cell, overrides);
            let u = match cell.underline_color() {
                _ if cf.contains(Flags::HIDDEN) => b,
                Some(c) => self.palette.resolve(c, overrides, cf, false),
                None => f,
            };

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
            // are a softer yellow so it stands out among them. It is the
            // selection, but only where the text still matches: output can
            // overwrite it.
            let point = Point::new(line, Column(col));
            let focused = out & frame::flags::MATCH != 0
                && focused_sel.is_some_and(|sel| sel.contains(point));
            if focused {
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
            underline.push(u);
        }

        RowUpdate {
            line: viewport_line as u16,
            glyphs,
            fg,
            bg,
            flags: flags_out,
            underline,
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
    fn search_reaches_every_match_in_a_long_history() {
        let mut e = emu();
        for i in 0..6_000 {
            e.feed(format!("{i} x x\r\n").as_bytes());
        }
        e.feed(b"newest x");
        e.search_set(Some("x"));
        let hit = e.search_step(true).unwrap();
        assert_eq!((hit.index, hit.total), (12_001, 12_001), "the newest first");
        assert_eq!(hit.line, 3);
        assert_eq!(e.search_step(true).unwrap().index, 12_000);
        // Forwards past the newest wraps to the oldest still kept.
        e.search_step(false).unwrap();
        assert_eq!(e.search_step(false).unwrap().index, 1);
    }

    fn row(e: &mut Emulator, line: u16) -> RowUpdate {
        e.invalidate();
        e.frame()
            .rows_changed
            .into_iter()
            .find(|r| r.line == line)
            .unwrap()
    }

    #[test]
    fn the_focused_match_follows_output() {
        let p = Palette::promptly_dark();
        let mut e = emu();
        e.feed(b"a needle\r\nb");
        e.search_set(Some("needle"));
        assert_eq!(e.search_step(true).unwrap().line, 0);
        assert_eq!(row(&mut e, 0).bg[2], p.ansi[3]);

        // Output scrolls it up a row: the highlight moves with the text.
        e.feed(b"\r\nc\r\nd\r\ne");
        assert_eq!(
            row(&mut e, 0).bg[2],
            p.background,
            "c, d and e are not matches"
        );
        e.scroll(1);
        assert_eq!(row(&mut e, 0).bg[2], p.ansi[3]);
        e.scroll(-1);

        // Overwritten text is not drawn as a match any more.
        let mut e = emu();
        e.feed(b"a needle");
        e.search_set(Some("needle"));
        e.search_step(true).unwrap();
        e.feed(b"\rabcdefgh");
        let r = row(&mut e, 0);
        assert!(r.flags.iter().all(|f| f & frame::flags::MATCH == 0));
        assert_ne!(r.bg[2], p.ansi[3]);
    }

    #[test]
    fn selecting_by_hand_drops_the_search_focus() {
        let p = Palette::promptly_dark();
        let mut e = emu();
        e.feed(b"needle needle");
        e.search_set(Some("needle"));
        e.search_step(true).unwrap();
        assert_eq!(row(&mut e, 0).bg[7], p.ansi[3]);
        e.select_begin(0, 0, false, SelectKind::Simple);
        e.select_update(12, 0, true);
        let r = row(&mut e, 0);
        assert_eq!(
            r.bg[7], p.selection,
            "a selection made by hand looks like one"
        );
        e.select_clear();
        // Stepping again starts from the bottom of the screen.
        assert_eq!(e.search_step(true).unwrap().index, 2);
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
        assert_ne!(first.flags[27] & frame::flags::LINK, 0);
        assert_eq!(
            first.flags[28] & frame::flags::LINK,
            0,
            "the comma after the url is not part of it"
        );
        assert_eq!(
            e.link_at(10, 0),
            Some(Link {
                uri: "https://example.com/docs".into(),
                hidden: false
            }),
            "trailing punctuation is not part of the link"
        );
        assert_eq!(e.link_at(1, 0), None);

        let second = &f.rows_changed[1];
        assert_ne!(second.flags[0] & frame::flags::LINK, 0);
        assert_ne!(second.flags[7] & frame::flags::LINK, 0);
        assert_eq!(second.flags[9] & frame::flags::LINK, 0);
        assert_eq!(
            e.link_at(2, 1),
            Some(Link {
                uri: "https://hidden.example/x".into(),
                hidden: true
            }),
            "its text is not where it goes"
        );
        assert_eq!(e.link_at(12, 1), None);

        // A hyperlink that shows its own address hides nothing.
        e.feed(b"\r\n\x1b]8;;https://a.example/\x1b\\https://a.example/\x1b]8;;\x1b\\");
        assert_eq!(e.link_at(3, 2).map(|l| l.hidden), Some(false));
    }

    #[test]
    fn a_link_with_a_part_you_cannot_see_asks_first() {
        let mut e = Emulator::new(TermSize::new(80, 4), Palette::promptly_dark());
        // Its text matches its address, but the host part is concealed.
        e.feed(b"\x1b]8;;https://trusted.example@evil.example/\x1b\\https://trusted.example\x1b[8m@evil.example/\x1b[28m\x1b]8;;\x1b\\\r\n");
        assert_eq!(e.link_at(3, 0).map(|l| l.hidden), Some(true));
        // The same trick on a plain address the terminal spotted itself.
        e.feed(b"https://trusted.example\x1b[8m@evil.example/\x1b[28m\r\n");
        assert_eq!(e.link_at(3, 1).map(|l| l.hidden), Some(true));
        // Or drawn in the background colour instead of concealed.
        e.feed(b"https://trusted.example\x1b[30;40m@evil.example/\x1b[0m\r\n");
        assert_eq!(e.link_at(3, 2).map(|l| l.hidden), Some(true));
        // The same black written two different ways, as a plain address
        // and as a hyperlink whose text matches its address.
        e.feed(b"https://trusted.example\x1b[38;2;0;0;0;48;5;16m@evil.example/\x1b[0m");
        assert_eq!(e.link_at(3, 3).map(|l| l.hidden), Some(true));
        let mut e = Emulator::new(TermSize::new(80, 4), Palette::promptly_dark());
        e.feed(b"\x1b]8;;https://trusted.example@evil.example/\x1b\\https://trusted.example\x1b[38;2;0;0;0;48;5;16m@evil.example/\x1b[0m\x1b]8;;\x1b\\\r\n");
        assert_eq!(e.link_at(3, 0).map(|l| l.hidden), Some(true));
        // Nearly the background colour is as good as hidden.
        e.feed(b"https://trusted.example\x1b[38;2;8;8;8;48;2;0;0;0m@evil.example/\x1b[0m\r\n");
        assert_eq!(e.link_at(3, 1).map(|l| l.hidden), Some(true));
        // Ordinary coloured text is still just a link.
        e.feed(b"\x1b[32mhttps://trusted.example/\x1b[0m");
        assert_eq!(e.link_at(3, 2).map(|l| l.hidden), Some(false));
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

    #[test]
    fn paths_and_addresses_are_flagged_apart_from_links() {
        let mut e = Emulator::new(TermSize::new(60, 4), Palette::promptly_dark());
        e.feed(b"log /var/log/syslog via 10.0.0.1:22 v1.2.3");
        let f = e.frame();
        let r = &f.rows_changed[0];
        let path = frame::flags::PATH_OR_ADDRESS;
        assert_eq!(r.flags[3] & path, 0);
        assert_ne!(r.flags[4] & path, 0);
        assert_ne!(r.flags[18] & path, 0);
        assert_eq!(
            r.flags[4] & frame::flags::LINK,
            0,
            "paths are not drawn as links"
        );
        assert_ne!(r.flags[24] & path, 0);
        assert_ne!(r.flags[34] & path, 0);
        assert!(r.flags[36..].iter().all(|f| f & path == 0), "not a version");
        assert_eq!(
            e.link_at(10, 0).map(|l| l.uri).as_deref(),
            Some("/var/log/syslog")
        );
        assert_eq!(
            e.link_at(30, 0).map(|l| l.uri).as_deref(),
            Some("10.0.0.1:22")
        );
        assert_eq!(e.link_at(38, 0), None);
    }

    #[test]
    fn underline_styles_and_colours_reach_the_frame() {
        let p = Palette::promptly_dark();
        let mut e = Emulator::new(TermSize::new(20, 2), Palette::promptly_dark());
        // Plain, curly in red (58;2), dotted in palette blue (58;5;4),
        // dashed, double, and curly after the colour was reset (59).
        e.feed(b"\x1b[4mA\x1b[4:3;58;2;255;0;0mB\x1b[4:4;58;5;4mC\x1b[59;4:5mD\x1b[4:2mE\x1b[0m");
        e.feed(b"\x1b[31;4:3mF\x1b[0m");
        let f = e.frame();
        let r = &f.rows_changed[0];
        assert_ne!(r.flags[0] & frame::flags::UNDERLINE, 0);
        assert_ne!(r.flags[1] & frame::flags::UNDERCURL, 0);
        assert_ne!(r.flags[2] & frame::flags::DOTTED_UNDERLINE, 0);
        assert_ne!(r.flags[3] & frame::flags::DASHED_UNDERLINE, 0);
        assert_ne!(r.flags[4] & frame::flags::DOUBLE_UNDERLINE, 0);
        assert_eq!(
            r.flags[1] & frame::flags::UNDERLINE,
            0,
            "one style at a time"
        );
        assert_eq!(r.underline[0], p.foreground, "no colour set: the text's");
        assert_eq!(r.underline[1], 0xFF0000);
        assert_eq!(r.underline[2], p.ansi[4]);
        assert_eq!(r.underline[3], p.foreground, "59 resets it");
        assert_ne!(r.flags[5] & frame::flags::UNDERCURL, 0);
        assert_eq!(r.underline[5], p.ansi[1], "follows red text");
    }

    #[test]
    fn scrollback_keeps_the_lines_asked_for() {
        let mut e = Emulator::with_scrollback(TermSize::new(20, 4), Palette::promptly_dark(), 50);
        for i in 0..200 {
            e.feed(format!("{i}\r\n").as_bytes());
        }
        assert_eq!(e.frame().history_len, 50);
        // Asking for more than the most allowed gets the most allowed.
        let mut big =
            Emulator::with_scrollback(TermSize::new(2, 4), Palette::promptly_dark(), 1 << 30);
        big.feed(&b"x\r\n".repeat(MAX_SCROLLBACK + 100));
        assert_eq!(big.frame().history_len as usize, MAX_SCROLLBACK);
    }

    #[test]
    fn a_synchronized_update_that_never_ends_is_shown_after_a_while() {
        let mut e = emu();
        e.feed(b"before");
        let _ = e.frame();

        // Begun and ended: shown at once.
        e.feed(b"\x1b[?2026h\rfirst\x1b[?2026l");
        assert!(e.screen_text().starts_with("first"));
        assert!(e.sync_deadline().is_none());

        // Begun and never ended: held back until its deadline.
        e.feed(b"\x1b[?2026h\rsecond\x07");
        assert!(e.screen_text().starts_with("first"), "held back for now");
        let deadline = e.sync_deadline().expect("a deadline");
        assert!(deadline <= Instant::now() + std::time::Duration::from_millis(150));
        assert!(e.end_stalled_sync(Instant::now()).is_none(), "not due yet");
        let events = e.end_stalled_sync(deadline).expect("due");
        assert!(
            events.contains(&EmulatorEvent::Bell),
            "its bell still rings"
        );
        assert!(e.screen_text().starts_with("second"));
        assert!(e.sync_deadline().is_none());
        assert!(e.frame().rows_changed.iter().any(|r| r.glyphs[0] == "s"));

        // Output arriving after the deadline is not held back either.
        e.feed(b"\x1b[?2026h\rthird!");
        std::thread::sleep(std::time::Duration::from_millis(160));
        e.feed(b" more");
        assert!(e.screen_text().starts_with("third! more"));
    }
}
