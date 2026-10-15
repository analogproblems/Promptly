//! The built-in theme gallery.
//!
//! Colours are the ones each theme publishes for terminals. Ids are stable
//! slugs: they are stored in settings, so renaming one is a format change.

use crate::palette::{Palette, Rgb};

#[allow(clippy::too_many_arguments)]
fn theme(
    id: &str,
    name: &str,
    dark: bool,
    foreground: Rgb,
    background: Rgb,
    cursor: Rgb,
    cursor_text: Rgb,
    selection: Rgb,
    ansi: [Rgb; 16],
) -> Palette {
    Palette {
        id: id.into(),
        name: name.into(),
        dark,
        foreground,
        background,
        cursor,
        cursor_text,
        selection,
        ansi,
        bright_bold: false,
    }
}

/// Every built-in theme, Promptly's own two first, then the rest in the
/// order the gallery shows them.
pub fn builtin() -> Vec<Palette> {
    vec![
        Palette::promptly_dark(),
        Palette::promptly_light(),
        theme(
            "catppuccin-mocha",
            "Catppuccin Mocha",
            true,
            0xCDD6F4,
            0x1E1E2E,
            0xF5E0DC,
            0x1E1E2E,
            0x585B70,
            [
                0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
            ],
        ),
        theme(
            "catppuccin-macchiato",
            "Catppuccin Macchiato",
            true,
            0xCAD3F5,
            0x24273A,
            0xF4DBD6,
            0x24273A,
            0x5B6078,
            [
                0x494D64, 0xED8796, 0xA6DA95, 0xEED49F, 0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xB8C0E0,
                0x5B6078, 0xED8796, 0xA6DA95, 0xEED49F, 0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xA5ADCB,
            ],
        ),
        theme(
            "catppuccin-frappe",
            "Catppuccin Frappé",
            true,
            0xC6D0F5,
            0x303446,
            0xF2D5CF,
            0x303446,
            0x626880,
            [
                0x51576D, 0xE78284, 0xA6D189, 0xE5C890, 0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xB5BFE2,
                0x626880, 0xE78284, 0xA6D189, 0xE5C890, 0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xA5ADCE,
            ],
        ),
        theme(
            "catppuccin-latte",
            "Catppuccin Latte",
            false,
            0x4C4F69,
            0xEFF1F5,
            0xDC8A78,
            0xEFF1F5,
            0xACB0BE,
            [
                0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
                0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC,
            ],
        ),
        theme(
            "dracula",
            "Dracula",
            true,
            0xF8F8F2,
            0x282A36,
            0xF8F8F2,
            0x282A36,
            0x44475A,
            [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
            ],
        ),
        theme(
            "nord",
            "Nord",
            true,
            0xD8DEE9,
            0x2E3440,
            0xD8DEE9,
            0x2E3440,
            0x434C5E,
            [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
            ],
        ),
        theme(
            "gruvbox-dark",
            "Gruvbox Dark",
            true,
            0xEBDBB2,
            0x282828,
            0xEBDBB2,
            0x282828,
            0x504945,
            [
                0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
            ],
        ),
        theme(
            "gruvbox-light",
            "Gruvbox Light",
            false,
            0x3C3836,
            0xFBF1C7,
            0x3C3836,
            0xFBF1C7,
            0xD5C4A1,
            [
                0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
                0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836,
            ],
        ),
        theme(
            "solarized-dark",
            "Solarized Dark",
            true,
            0x839496,
            0x002B36,
            0x839496,
            0x002B36,
            0x073642,
            [
                0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
            ],
        ),
        theme(
            "solarized-light",
            "Solarized Light",
            false,
            0x657B83,
            0xFDF6E3,
            0x657B83,
            0xFDF6E3,
            0xEEE8D5,
            [
                0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
            ],
        ),
        theme(
            "one-dark",
            "One Dark",
            true,
            0xABB2BF,
            0x282C34,
            0x528BFF,
            0x282C34,
            0x3E4451,
            [
                0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
            ],
        ),
        theme(
            "tokyo-night",
            "Tokyo Night",
            true,
            0xC0CAF5,
            0x1A1B26,
            0xC0CAF5,
            0x1A1B26,
            0x33467C,
            [
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
            ],
        ),
        theme(
            "rose-pine",
            "Rosé Pine",
            true,
            0xE0DEF4,
            0x191724,
            0x524F67,
            0xE0DEF4,
            0x403D52,
            [
                0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
                0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            ],
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// Perceived brightness, 0 to 255.
    fn luma(c: Rgb) -> u32 {
        let r = (c >> 16) & 0xFF;
        let g = (c >> 8) & 0xFF;
        let b = c & 0xFF;
        (r * 299 + g * 587 + b * 114) / 1000
    }

    #[test]
    fn ids_are_unique_slugs_and_dark_matches_the_background() {
        let all = builtin();
        assert_eq!(all.len(), 15);
        let ids: HashSet<&str> = all.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids.len(), all.len(), "duplicate theme id");
        for p in &all {
            assert!(
                p.id.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "{} is not a slug",
                p.id
            );
            assert_eq!(
                p.dark,
                luma(p.background) < 128,
                "{}: dark flag disagrees with its background",
                p.name
            );
            assert_ne!(p.foreground, p.background, "{}: invisible text", p.name);
        }
    }

    #[test]
    fn lookup_by_id() {
        assert_eq!(Palette::builtin("dracula").unwrap().name, "Dracula");
        assert_eq!(
            Palette::builtin("promptly-light"),
            Some(Palette::promptly_light())
        );
        assert!(Palette::builtin("no-such-theme").is_none());
    }
}
