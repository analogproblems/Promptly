//! Terminal colour palettes and colour resolution.

use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::vte::ansi::{Color, NamedColor};

/// A colour packed as `0xRRGGBB`.
pub type Rgb = u32;

const fn rgb(r: u8, g: u8, b: u8) -> Rgb {
    ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
}

/// Everything a terminal theme decides. Matches the `Theme` record in the
/// vault; the vault stores hex strings, this is the resolved form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Palette {
    /// Stable identifier: a slug such as `promptly-dark` for a built-in
    /// theme, a record id for one the user added.
    pub id: String,
    pub name: String,
    /// True when the background is dark. The app uses it to pick chrome
    /// colours that sit well next to the terminal.
    pub dark: bool,
    pub foreground: Rgb,
    pub background: Rgb,
    pub cursor: Rgb,
    /// Text colour inside a block cursor.
    pub cursor_text: Rgb,
    pub selection: Rgb,
    /// The 16 ANSI colours: 0-7 normal, 8-15 bright.
    pub ansi: [Rgb; 16],
    /// Draw bold text in the bright variant of the eight basic colours.
    pub bright_bold: bool,
}

impl Palette {
    /// Promptly's own dark theme, matched to the app's design tokens.
    pub fn promptly_dark() -> Self {
        Self {
            id: "promptly-dark".into(),
            name: "Promptly Dark".into(),
            dark: true,
            foreground: rgb(0xE6, 0xED, 0xF3),
            background: rgb(0x0E, 0x11, 0x16),
            cursor: rgb(0x7C, 0xE3, 0x8B),
            cursor_text: rgb(0x0E, 0x11, 0x16),
            selection: rgb(0x26, 0x3A, 0x4F),
            ansi: [
                rgb(0x16, 0x1B, 0x22), // black
                rgb(0xFF, 0x7B, 0x72), // red
                rgb(0x7C, 0xE3, 0x8B), // green
                rgb(0xE3, 0xB3, 0x41), // yellow
                rgb(0x79, 0xC0, 0xFF), // blue
                rgb(0xD2, 0xA8, 0xFF), // magenta
                rgb(0x76, 0xE3, 0xEA), // cyan
                rgb(0xB1, 0xBA, 0xC4), // white
                rgb(0x6E, 0x76, 0x81), // bright black
                rgb(0xFF, 0xA1, 0x98), // bright red
                rgb(0xA5, 0xEF, 0xB0), // bright green
                rgb(0xF2, 0xCC, 0x60), // bright yellow
                rgb(0xA5, 0xD6, 0xFF), // bright blue
                rgb(0xE2, 0xC5, 0xFF), // bright magenta
                rgb(0xB3, 0xF0, 0xFF), // bright cyan
                rgb(0xF0, 0xF6, 0xFC), // bright white
            ],
            bright_bold: false,
        }
    }

    /// Promptly's light theme.
    pub fn promptly_light() -> Self {
        Self {
            id: "promptly-light".into(),
            name: "Promptly Light".into(),
            dark: false,
            foreground: rgb(0x1F, 0x23, 0x28),
            background: rgb(0xFA, 0xFA, 0xF7),
            cursor: rgb(0x1A, 0x7F, 0x37),
            cursor_text: rgb(0xFF, 0xFF, 0xFF),
            selection: rgb(0xD0, 0xE8, 0xFF),
            ansi: [
                rgb(0x24, 0x29, 0x2F), // black
                rgb(0xCF, 0x22, 0x2E), // red
                rgb(0x1A, 0x7F, 0x37), // green
                rgb(0x9A, 0x67, 0x00), // yellow
                rgb(0x09, 0x69, 0xDA), // blue
                rgb(0x82, 0x50, 0xDF), // magenta
                rgb(0x1B, 0x7C, 0x83), // cyan
                rgb(0x6E, 0x77, 0x81), // white
                rgb(0x57, 0x60, 0x6A), // bright black
                rgb(0xA4, 0x0E, 0x26), // bright red
                rgb(0x11, 0x6E, 0x29), // bright green
                rgb(0x7D, 0x4E, 0x00), // bright yellow
                rgb(0x05, 0x50, 0xAE), // bright blue
                rgb(0x6E, 0x40, 0xC9), // bright magenta
                rgb(0x3E, 0x9A, 0xA3), // bright cyan
                rgb(0x1F, 0x23, 0x28), // bright white
            ],
            bright_bold: false,
        }
    }

    /// A built-in theme by id, or `None` if there is no such theme.
    pub fn builtin(id: &str) -> Option<Palette> {
        crate::themes::builtin().into_iter().find(|p| p.id == id)
    }

    /// The colour for one of the 256 indexed colours, before any override the
    /// running program set with OSC 4.
    pub fn indexed(&self, index: u8) -> Rgb {
        match index {
            0..=15 => self.ansi[index as usize],
            16..=231 => {
                let i = index - 16;
                let r = i / 36;
                let g = (i % 36) / 6;
                let b = i % 6;
                let level = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
                rgb(level(r), level(g), level(b))
            }
            232..=255 => {
                let v = 8 + (index - 232) * 10;
                rgb(v, v, v)
            }
        }
    }

    fn named(&self, color: NamedColor) -> Rgb {
        match color {
            NamedColor::Foreground | NamedColor::BrightForeground => self.foreground,
            NamedColor::Background => self.background,
            NamedColor::Cursor => self.cursor,
            NamedColor::DimForeground => dim(self.foreground),
            NamedColor::DimBlack
            | NamedColor::DimRed
            | NamedColor::DimGreen
            | NamedColor::DimYellow
            | NamedColor::DimBlue
            | NamedColor::DimMagenta
            | NamedColor::DimCyan
            | NamedColor::DimWhite => {
                dim(self.ansi[color as usize - NamedColor::DimBlack as usize])
            }
            other => self.ansi[other as usize & 0x0F],
        }
    }

    /// Resolve a cell colour. `overrides` is the terminal's own table, which
    /// programs can change at runtime; the palette fills whatever is unset.
    pub fn resolve(&self, color: Color, overrides: &Colors, flags: Flags, is_fg: bool) -> Rgb {
        match color {
            Color::Spec(c) => pack(c),
            Color::Indexed(i) => {
                let i = if is_fg && self.bright_bold && flags.contains(Flags::BOLD) && i < 8 {
                    i + 8
                } else {
                    i
                };
                overrides[i as usize]
                    .map(pack)
                    .unwrap_or_else(|| self.indexed(i))
            }
            Color::Named(n) => {
                let n = if is_fg && self.bright_bold && flags.contains(Flags::BOLD) {
                    brighten(n)
                } else {
                    n
                };
                overrides[n].map(pack).unwrap_or_else(|| self.named(n))
            }
        }
    }
}

fn brighten(n: NamedColor) -> NamedColor {
    match n {
        NamedColor::Black => NamedColor::BrightBlack,
        NamedColor::Red => NamedColor::BrightRed,
        NamedColor::Green => NamedColor::BrightGreen,
        NamedColor::Yellow => NamedColor::BrightYellow,
        NamedColor::Blue => NamedColor::BrightBlue,
        NamedColor::Magenta => NamedColor::BrightMagenta,
        NamedColor::Cyan => NamedColor::BrightCyan,
        NamedColor::White => NamedColor::BrightWhite,
        other => other,
    }
}

/// Two thirds brightness, the convention other terminals use for "dim".
pub fn dim(c: Rgb) -> Rgb {
    let scale = |v: u32| (v * 2 / 3) & 0xFF;
    (scale((c >> 16) & 0xFF) << 16) | (scale((c >> 8) & 0xFF) << 8) | scale(c & 0xFF)
}

/// `a` moved `t` of the way towards `b`.
pub(crate) fn mix(a: Rgb, b: Rgb, t: f64) -> Rgb {
    let m = |x: u32, y: u32| ((x as f64) * (1.0 - t) + (y as f64) * t).round() as u32;
    m(a >> 16 & 0xFF, b >> 16 & 0xFF) << 16
        | m(a >> 8 & 0xFF, b >> 8 & 0xFF) << 8
        | m(a & 0xFF, b & 0xFF)
}

pub(crate) fn pack(c: alacritty_terminal::vte::ansi::Rgb) -> Rgb {
    rgb(c.r, c.g, c.b)
}

pub(crate) fn unpack(c: Rgb) -> alacritty_terminal::vte::ansi::Rgb {
    alacritty_terminal::vte::ansi::Rgb {
        r: ((c >> 16) & 0xFF) as u8,
        g: ((c >> 8) & 0xFF) as u8,
        b: (c & 0xFF) as u8,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indexed_cube_and_grayscale_match_xterm() {
        let p = Palette::promptly_dark();
        assert_eq!(p.indexed(16), 0x000000);
        assert_eq!(p.indexed(21), 0x0000FF);
        assert_eq!(p.indexed(196), 0xFF0000);
        assert_eq!(p.indexed(231), 0xFFFFFF);
        assert_eq!(p.indexed(232), 0x080808);
        assert_eq!(p.indexed(255), 0xEEEEEE);
    }

    #[test]
    fn overrides_win_over_the_palette() {
        let p = Palette::promptly_dark();
        let mut overrides = Colors::default();
        assert_eq!(
            p.resolve(
                Color::Named(NamedColor::Red),
                &overrides,
                Flags::empty(),
                true
            ),
            p.ansi[1]
        );
        overrides[NamedColor::Red] = Some(unpack(0x123456));
        assert_eq!(
            p.resolve(
                Color::Named(NamedColor::Red),
                &overrides,
                Flags::empty(),
                true
            ),
            0x123456
        );
    }

    #[test]
    fn dim_is_two_thirds() {
        assert_eq!(dim(0xFFFFFF), 0xAAAAAA);
        assert_eq!(dim(0x000000), 0x000000);
    }
}
