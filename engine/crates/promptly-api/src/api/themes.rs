//! The theme gallery: every built-in terminal theme plus the ones the user
//! imported, with their colours, so the app can draw previews without
//! opening a session. Imported themes are records in the `themes`
//! collection, so they sync like everything else.

use flutter_rust_bridge::frb;
use promptly_store::Collection;
use promptly_term::Palette;
use promptly_vault::model::{Theme, ThemeColors};

use crate::api::store::{record_delete, record_put, store};

pub struct ThemeInfo {
    /// Stable id, the value stored in settings: a slug for a built-in
    /// theme, a record id for an imported one, empty for a preview.
    pub id: String,
    pub name: String,
    pub dark: bool,
    pub foreground: u32,
    pub background: u32,
    pub cursor: u32,
    pub selection: u32,
    /// The 16 ANSI colours, 0-7 normal and 8-15 bright.
    pub ansi: Vec<u32>,
    pub builtin: bool,
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
            builtin: true,
        }
    }
}

fn hex(c: u32) -> String {
    format!("#{:06x}", c & 0xFFFFFF)
}

/// A vault theme record as a palette; None when its colours are not hex.
pub(crate) fn palette_of(theme: &Theme) -> Option<Palette> {
    let parse = promptly_term::theme_import::parse_hex;
    let mut ansi = [0u32; 16];
    for (i, c) in theme.colors.ansi.iter().enumerate() {
        ansi[i] = parse(c)?;
    }
    let background = parse(&theme.colors.bg)?;
    let foreground = parse(&theme.colors.fg)?;
    Some(Palette {
        id: theme.id.to_string(),
        name: theme.name.clone(),
        dark: luminance(background) < 0.4,
        foreground,
        background,
        cursor: parse(&theme.colors.cursor)?,
        cursor_text: background,
        selection: parse(&theme.colors.selection)?,
        ansi,
        bright_bold: false,
    })
}

fn luminance(c: u32) -> f64 {
    let ch = |v: u32| {
        let v = v as f64 / 255.0;
        if v <= 0.03928 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * ch(c >> 16 & 0xFF) + 0.7152 * ch(c >> 8 & 0xFF) + 0.0722 * ch(c & 0xFF)
}

/// The themes the user imported, from the store.
fn custom() -> Vec<Theme> {
    store()
        .ok()
        .and_then(|s| s.list(Collection::Themes).ok())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|r| serde_json::from_str::<Theme>(&r.json).ok())
        .collect()
}

/// The palette for a theme id: built in, or imported, or Promptly Dark
/// when the id is unknown so a stale setting never leaves a session
/// without colours.
pub(crate) fn palette_for(id: &str) -> Palette {
    if let Some(p) = Palette::builtin(id) {
        return p;
    }
    custom()
        .iter()
        .find(|t| t.id.to_string() == id)
        .and_then(palette_of)
        .unwrap_or_else(Palette::promptly_dark)
}

#[frb(sync)]
pub fn themes_list() -> Vec<ThemeInfo> {
    let mut out: Vec<ThemeInfo> = promptly_term::themes::builtin()
        .into_iter()
        .map(Into::into)
        .collect();
    let mut mine: Vec<ThemeInfo> = custom()
        .iter()
        .filter_map(palette_of)
        .map(|p| ThemeInfo {
            builtin: false,
            ..p.into()
        })
        .collect();
    mine.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out.extend(mine);
    out
}

/// Read a theme file (iTerm2, Windows Terminal, Alacritty, base16) without
/// saving anything: one entry per scheme in the file, ids empty.
#[frb(sync)]
pub fn theme_import_preview(text: String, filename: String) -> Result<Vec<ThemeInfo>, String> {
    Ok(promptly_term::theme_import::parse(&text, &filename)?
        .into_iter()
        .map(|p| ThemeInfo {
            builtin: false,
            ..p.into()
        })
        .collect())
}

/// Save a previewed theme as a record. Returns it with its new id.
#[frb(sync)]
pub fn theme_save(theme: ThemeInfo) -> Result<ThemeInfo, String> {
    if theme.ansi.len() != 16 {
        return Err("a theme needs its 16 ANSI colours".into());
    }
    let name = theme.name.trim();
    if name.is_empty() {
        return Err("the theme needs a name".into());
    }
    let record = Theme {
        id: promptly_vault::model::new_id(),
        name: name.to_string(),
        colors: ThemeColors {
            fg: hex(theme.foreground),
            bg: hex(theme.background),
            cursor: hex(theme.cursor),
            selection: hex(theme.selection),
            ansi: std::array::from_fn(|i| hex(theme.ansi[i])),
        },
        builtin: false,
    };
    record_put(
        "themes".into(),
        record.id.to_string(),
        serde_json::to_string(&record).map_err(|e| e.to_string())?,
    )?;
    Ok(ThemeInfo {
        id: record.id.to_string(),
        name: record.name,
        builtin: false,
        ..theme
    })
}

/// Remove an imported theme. Built-in ids are refused.
#[frb(sync)]
pub fn theme_delete(id: String) -> Result<(), String> {
    if Palette::builtin(&id).is_some() {
        return Err("built-in themes cannot be removed".into());
    }
    record_delete("themes".into(), id)?;
    Ok(())
}
