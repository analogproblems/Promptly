//! Terminal emulation for Promptly.
//!
//! This crate owns the screen grid, scrollback, cursor and terminal modes, and
//! turns raw bytes from a shell or SSH channel into frame updates the UI can
//! paint. Milestone 1 wraps `alacritty_terminal` here; milestone 0 only fixes
//! the public shapes that the rest of the engine and the app depend on.

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
