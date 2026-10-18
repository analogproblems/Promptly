//! Terminal emulation for Promptly.
//!
//! This crate owns the screen grid, scrollback, cursor and terminal modes, and
//! turns raw bytes from a shell or SSH channel into [`Frame`] updates the UI
//! can paint. Emulation itself is `alacritty_terminal`, the engine behind the
//! Alacritty terminal; this crate adapts it, resolves colours against a
//! [`Palette`] and tracks which rows changed so the UI repaints only those.

pub mod emulator;
pub mod frame;
pub mod links;
pub mod mouse;
pub mod palette;
pub mod theme_import;
pub mod themes;

pub use emulator::{
    Emulator, EmulatorEvent, Link, SearchHit, SelectKind, DEFAULT_SCROLLBACK, MAX_SCROLLBACK,
};
pub use frame::{flags, CursorShape, CursorState, Frame, RowUpdate};
pub use mouse::{MouseAction, MouseButton, MouseEvent};
pub use palette::{Palette, Rgb};

use serde::{Deserialize, Serialize};

/// Size of a terminal in character cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TermSize {
    pub cols: u16,
    pub rows: u16,
}

impl TermSize {
    /// A size, clamped so that neither dimension is zero.
    pub fn new(cols: u16, rows: u16) -> Self {
        Self {
            cols: cols.max(1),
            rows: rows.max(1),
        }
    }

    /// Number of cells on screen.
    pub fn cells(&self) -> usize {
        usize::from(self.cols) * usize::from(self.rows)
    }
}

impl Default for TermSize {
    fn default() -> Self {
        Self::new(80, 24)
    }
}

impl alacritty_terminal::grid::Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        self.rows as usize
    }
    fn screen_lines(&self) -> usize {
        self.rows as usize
    }
    fn columns(&self) -> usize {
        self.cols as usize
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn size_never_has_a_zero_dimension() {
        let s = TermSize::new(0, 0);
        assert_eq!(s, TermSize { cols: 1, rows: 1 });
        assert_eq!(TermSize::default().cells(), 80 * 24);
    }
}
