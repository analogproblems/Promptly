//! The theme gallery: every built-in terminal theme with its colours, so the
//! app can draw previews without opening a session.

use flutter_rust_bridge::frb;
use promptly_term::Palette;

pub struct ThemeInfo {
    /// Stable id, the value stored in settings. See `promptly_term::themes`.
    pub id: String,
    pub name: String,
    pub dark: bool,
    pub foreground: u32,
    pub background: u32,
    pub cursor: u32,
    pub selection: u32,
    /// The 16 ANSI colours, 0-7 normal and 8-15 bright.
    pub ansi: Vec<u32>,
}

impl From<Palette> for ThemeInfo {
    fn from(p: Palette) -> Self {
        ThemeInfo {
            id: p.id,
            name: p.name,
            dark: p.dark,
            foreground: p.foreground,
            background: p.background,
            cursor: p.cursor,
            selection: p.selection,
            ansi: p.ansi.to_vec(),
        }
    }
}

#[frb(sync)]
pub fn themes_list() -> Vec<ThemeInfo> {
    promptly_term::themes::builtin()
        .into_iter()
        .map(Into::into)
        .collect()
}
