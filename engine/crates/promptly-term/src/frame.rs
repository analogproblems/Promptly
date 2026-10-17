//! What the UI receives: the rows that changed and where the cursor is.

use crate::palette::Rgb;

/// Style bits on a cell, stable across versions because the UI depends on
/// them. Inverse and hidden are already applied to the colours and are not
/// sent.
pub mod flags {
    pub const BOLD: u16 = 1 << 0;
    pub const ITALIC: u16 = 1 << 1;
    pub const UNDERLINE: u16 = 1 << 2;
    pub const STRIKEOUT: u16 = 1 << 3;
    pub const DIM: u16 = 1 << 4;
    /// This cell is the first half of a double-width character.
    pub const WIDE: u16 = 1 << 5;
    /// This cell is the second half of a double-width character; draw nothing.
    pub const WIDE_SPACER: u16 = 1 << 6;
    pub const DOUBLE_UNDERLINE: u16 = 1 << 7;
    pub const UNDERCURL: u16 = 1 << 8;
    pub const DOTTED_UNDERLINE: u16 = 1 << 9;
    pub const DASHED_UNDERLINE: u16 = 1 << 10;
    /// This cell is inside the current selection.
    pub const SELECTED: u16 = 1 << 11;
    /// This cell is part of a search match (the colours already show it).
    pub const MATCH: u16 = 1 << 12;
    /// This cell is part of a link: an OSC 8 hyperlink or a URL in the text.
    pub const LINK: u16 = 1 << 13;
    /// This cell is part of a file path or IP address in the text. It can be
    /// clicked like a link but is not underlined, since paths are everywhere
    /// (the prompt, `ls -l`) and would make the screen busy.
    pub const PATH_OR_ADDRESS: u16 = 1 << 14;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Underline,
    Beam,
    HollowBlock,
    Hidden,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorState {
    /// Row in the viewport. May be past the last row while scrolled back.
    pub line: i32,
    pub col: u16,
    pub shape: CursorShape,
}

/// One changed row, as parallel arrays so the UI can keep them as typed lists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowUpdate {
    pub line: u16,
    /// One entry per column: the grapheme in the cell, empty for a spacer.
    pub glyphs: Vec<String>,
    pub fg: Vec<Rgb>,
    pub bg: Vec<Rgb>,
    pub flags: Vec<u16>,
    /// The underline colour per column: the one the program set (SGR 58)
    /// or else the text colour.
    pub underline: Vec<Rgb>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub cols: u16,
    pub rows: u16,
    /// When true, `rows_changed` holds every row and the UI should drop what
    /// it had.
    pub full: bool,
    pub rows_changed: Vec<RowUpdate>,
    pub cursor: CursorState,
    /// How many lines back into history the viewport is scrolled.
    pub display_offset: u32,
    /// How many lines of history exist.
    pub history_len: u32,
    pub default_fg: Rgb,
    pub default_bg: Rgb,
    pub cursor_color: Rgb,
    pub title: Option<String>,
    pub bell: bool,
    /// The program asked for application cursor keys (arrows send SS3).
    pub app_cursor: bool,
    /// The program is showing the alternate screen (vim, htop, less).
    pub alt_screen: bool,
    pub bracketed_paste: bool,
    /// The program wants mouse events.
    pub mouse_reporting: bool,
}
