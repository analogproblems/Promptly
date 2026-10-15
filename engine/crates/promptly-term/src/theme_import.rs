//! Reading other terminals' theme files: iTerm2 `.itermcolors`, Windows
//! Terminal colour schemes, Alacritty's TOML and YAML, and base16 (or
//! base24) YAML. Each becomes a `Palette` with an empty id; whoever saves
//! it assigns one.
//!
//! The parsers are deliberately small and only read the shapes those files
//! actually take, so no XML, TOML or YAML library is pulled in.

use std::collections::BTreeMap;

use crate::palette::{Palette, Rgb};

/// Which kind of file this looks like, from its content and name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThemeFormat {
    ITerm2,
    WindowsTerminal,
    AlacrittyToml,
    AlacrittyYaml,
    Base16,
}

impl ThemeFormat {
    pub fn name(self) -> &'static str {
        match self {
            ThemeFormat::ITerm2 => "iTerm2",
            ThemeFormat::WindowsTerminal => "Windows Terminal",
            ThemeFormat::AlacrittyToml => "Alacritty",
            ThemeFormat::AlacrittyYaml => "Alacritty",
            ThemeFormat::Base16 => "base16",
        }
    }
}

pub fn detect(text: &str, filename: &str) -> Option<ThemeFormat> {
    let lower = filename.to_ascii_lowercase();
    let t = text.trim_start();
    if t.contains("<plist") || lower.ends_with(".itermcolors") {
        return Some(ThemeFormat::ITerm2);
    }
    if t.starts_with('{') || t.starts_with('[') && lower.ends_with(".json") {
        return Some(ThemeFormat::WindowsTerminal);
    }
    if text.contains("base00") {
        return Some(ThemeFormat::Base16);
    }
    if text.contains("[colors") || text.contains("colors.") && text.contains('=') {
        return Some(ThemeFormat::AlacrittyToml);
    }
    if text.contains("colors:") {
        return Some(ThemeFormat::AlacrittyYaml);
    }
    None
}

/// Every theme in the file. `filename` names a theme whose format has no
/// name of its own.
pub fn parse(text: &str, filename: &str) -> Result<Vec<Palette>, String> {
    let format = detect(text, filename).ok_or_else(|| {
        "not a theme file Promptly knows: iTerm2 .itermcolors, Windows Terminal .json, Alacritty .toml or .yml, base16 .yaml".to_string()
    })?;
    let fallback = name_from_file(filename);
    let out = match format {
        ThemeFormat::ITerm2 => vec![iterm2(text, &fallback)?],
        ThemeFormat::WindowsTerminal => windows_terminal(text)?,
        ThemeFormat::AlacrittyToml => vec![alacritty_toml(text, &fallback)?],
        ThemeFormat::AlacrittyYaml => vec![alacritty_yaml(text, &fallback)?],
        ThemeFormat::Base16 => vec![base16(text, &fallback)?],
    };
    if out.is_empty() {
        return Err("the file holds no colour scheme".into());
    }
    Ok(out)
}

/// "Solarized Dark" from "solarized-dark.itermcolors".
fn name_from_file(filename: &str) -> String {
    let base = filename.rsplit(['/', '\\']).next().unwrap_or(filename);
    let stem = base.rsplit_once('.').map(|(s, _)| s).unwrap_or(base);
    let words: Vec<String> = stem
        .split(['-', '_', ' '])
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                None => String::new(),
            }
        })
        .collect();
    if words.is_empty() {
        "Imported theme".into()
    } else {
        words.join(" ")
    }
}

/// "#1d1f21", "0x1d1f21", "1d1f21" or "#abc".
pub fn parse_hex(s: &str) -> Option<Rgb> {
    let s = s.trim().trim_matches(|c| c == '"' || c == '\'');
    let hex = s
        .strip_prefix('#')
        .or_else(|| s.strip_prefix("0x"))
        .or_else(|| s.strip_prefix("0X"))
        .unwrap_or(s);
    match hex.len() {
        6 => u32::from_str_radix(hex, 16).ok(),
        8 => u32::from_str_radix(&hex[..6], 16).ok(),
        3 => {
            let v = u32::from_str_radix(hex, 16).ok()?;
            let (r, g, b) = ((v >> 8) & 0xF, (v >> 4) & 0xF, v & 0xF);
            Some((r * 17) << 16 | (g * 17) << 8 | (b * 17))
        }
        _ => None,
    }
}

fn luminance(c: Rgb) -> f64 {
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

fn mix(a: Rgb, b: Rgb, t: f64) -> Rgb {
    let m = |x: u32, y: u32| ((x as f64) * (1.0 - t) + (y as f64) * t).round() as u32;
    m(a >> 16 & 0xFF, b >> 16 & 0xFF) << 16
        | m(a >> 8 & 0xFF, b >> 8 & 0xFF) << 8
        | m(a & 0xFF, b & 0xFF)
}

/// The colours every format must supply, assembled into a palette.
struct Parts {
    name: String,
    foreground: Rgb,
    background: Rgb,
    cursor: Option<Rgb>,
    cursor_text: Option<Rgb>,
    selection: Option<Rgb>,
    ansi: [Option<Rgb>; 16],
}

const ANSI_NAMES: [&str; 8] = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
];

impl Parts {
    fn new(name: String, foreground: Rgb, background: Rgb) -> Self {
        Parts {
            name,
            foreground,
            background,
            cursor: None,
            cursor_text: None,
            selection: None,
            ansi: [None; 16],
        }
    }

    fn finish(self) -> Result<Palette, String> {
        let mut ansi = [0u32; 16];
        for (i, c) in self.ansi.iter().enumerate() {
            ansi[i] = c.ok_or_else(|| {
                format!(
                    "the theme is missing its {}{} colour",
                    if i >= 8 { "bright " } else { "" },
                    ANSI_NAMES[i % 8]
                )
            })?;
        }
        let dark = luminance(self.background) < 0.4;
        Ok(Palette {
            id: String::new(),
            name: self.name,
            dark,
            foreground: self.foreground,
            background: self.background,
            cursor: self.cursor.unwrap_or(self.foreground),
            cursor_text: self.cursor_text.unwrap_or(self.background),
            selection: self
                .selection
                .unwrap_or_else(|| mix(self.background, self.foreground, 0.25)),
            ansi,
            bright_bold: false,
        })
    }
}

// ---- iTerm2 ----------------------------------------------------------------

fn iterm2(text: &str, fallback_name: &str) -> Result<Palette, String> {
    // <key>Ansi 0 Color</key><dict> ... <key>Red Component</key><real>0.1</real> ... </dict>
    let mut colors: BTreeMap<String, Rgb> = BTreeMap::new();
    let mut rest = text;
    while let Some(start) = rest.find("<key>") {
        let after = &rest[start + 5..];
        let Some(end) = after.find("</key>") else {
            break;
        };
        let key = after[..end].trim().to_string();
        let after_key = &after[end + 6..];
        let next_tag = after_key.trim_start();
        if next_tag.starts_with("<dict>") {
            let Some(dict_end) = next_tag.find("</dict>") else {
                break;
            };
            let dict = &next_tag[..dict_end];
            let comp = |name: &str| -> Option<f64> {
                let k = format!("<key>{name} Component</key>");
                let i = dict.find(&k)? + k.len();
                let tail = dict[i..].trim_start();
                let v = tail.strip_prefix("<real>")?;
                let j = v.find("</real>")?;
                v[..j].trim().parse().ok()
            };
            if let (Some(r), Some(g), Some(b)) = (comp("Red"), comp("Green"), comp("Blue")) {
                let to8 = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
                colors.insert(key, to8(r) << 16 | to8(g) << 8 | to8(b));
            }
            rest = &next_tag[dict_end + 7..];
        } else {
            rest = after_key;
        }
    }
    let get = |k: &str| colors.get(k).copied();
    let fg = get("Foreground Color").ok_or("no Foreground Color in the file")?;
    let bg = get("Background Color").ok_or("no Background Color in the file")?;
    let mut p = Parts::new(fallback_name.to_string(), fg, bg);
    p.cursor = get("Cursor Color");
    p.cursor_text = get("Cursor Text Color");
    p.selection = get("Selection Color");
    for i in 0..16 {
        p.ansi[i] = get(&format!("Ansi {i} Color"));
    }
    p.finish()
}

// ---- Windows Terminal ------------------------------------------------------

fn windows_terminal(text: &str) -> Result<Vec<Palette>, String> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("not valid JSON: {e}"))?;
    let schemes: Vec<&serde_json::Value> = match value.get("schemes").and_then(|s| s.as_array()) {
        Some(list) => list.iter().collect(),
        None => vec![&value],
    };
    let mut out = Vec::new();
    for s in schemes {
        let color = |k: &str| s.get(k).and_then(|v| v.as_str()).and_then(parse_hex);
        let name = s
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("Windows Terminal scheme")
            .to_string();
        let fg = color("foreground").ok_or_else(|| format!("{name}: no foreground"))?;
        let bg = color("background").ok_or_else(|| format!("{name}: no background"))?;
        let mut p = Parts::new(name, fg, bg);
        p.cursor = color("cursorColor");
        p.selection = color("selectionBackground");
        const NAMES: [&str; 8] = [
            "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
        ];
        for (i, n) in NAMES.iter().enumerate() {
            p.ansi[i] = color(n);
            let mut bright = String::from("bright");
            bright.push_str(&n[..1].to_uppercase());
            bright.push_str(&n[1..]);
            p.ansi[i + 8] = color(&bright);
        }
        out.push(p.finish()?);
    }
    Ok(out)
}

// ---- Alacritty -------------------------------------------------------------

/// `section.key` -> value, for both the TOML and the YAML layouts.
type Flat = BTreeMap<String, String>;

/// Drop a trailing `# comment`, leaving `#` inside quotes (hex colours)
/// alone. Outside quotes a `#` starts a comment, as in TOML and YAML.
fn strip_comment(line: &str) -> &str {
    let mut quote: Option<char> = None;
    for (i, c) in line.char_indices() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None if c == '"' || c == '\'' => quote = Some(c),
            None if c == '#' => return &line[..i],
            None => {}
        }
    }
    line
}

fn unquote(v: &str) -> String {
    let v = strip_comment(v).trim();
    v.trim_matches(|c| c == '"' || c == '\'').to_string()
}

fn alacritty_from(flat: &Flat, fallback_name: &str) -> Result<Palette, String> {
    let get = |k: &str| flat.get(k).and_then(|v| parse_hex(v));
    let fg = get("colors.primary.foreground").ok_or("no colors.primary.foreground")?;
    let bg = get("colors.primary.background").ok_or("no colors.primary.background")?;
    let mut p = Parts::new(fallback_name.to_string(), fg, bg);
    p.cursor = get("colors.cursor.cursor");
    p.cursor_text = get("colors.cursor.text");
    p.selection = get("colors.selection.background");
    for (i, n) in ANSI_NAMES.iter().enumerate() {
        p.ansi[i] = get(&format!("colors.normal.{n}"));
        p.ansi[i + 8] = get(&format!("colors.bright.{n}"));
    }
    p.finish()
}

fn alacritty_toml(text: &str, fallback_name: &str) -> Result<Palette, String> {
    let mut flat = Flat::new();
    let mut section = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(inner) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = inner.trim().trim_matches('"').to_string();
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let key = k.trim().trim_matches('"');
        let full = if section.is_empty() {
            key.to_string()
        } else {
            format!("{section}.{key}")
        };
        let v = v.trim();
        if let Some(inline) = v.strip_prefix('{').and_then(|v| v.strip_suffix('}')) {
            // colors.primary = { background = "#000", foreground = "#fff" }
            for pair in inline.split(',') {
                if let Some((ik, iv)) = pair.split_once('=') {
                    flat.insert(
                        format!("{full}.{}", ik.trim().trim_matches('"')),
                        unquote(iv),
                    );
                }
            }
        } else {
            flat.insert(full, unquote(v));
        }
    }
    alacritty_from(&flat, fallback_name)
}

/// Flatten simple `key:` nesting by indentation into `a.b.c` keys.
fn yaml_flat(text: &str) -> Flat {
    let mut flat = Flat::new();
    let mut path: Vec<(usize, String)> = Vec::new();
    for raw in text.lines() {
        let line = strip_comment(raw).trim_end();
        if line.trim().is_empty() {
            continue;
        }
        let indent = line.len() - line.trim_start().len();
        let body = line.trim_start();
        let Some((k, v)) = body.split_once(':') else {
            continue;
        };
        let key = k.trim().trim_matches(|c| c == '"' || c == '\'').to_string();
        while path.last().is_some_and(|(i, _)| *i >= indent) {
            path.pop();
        }
        let v = v.trim();
        if v.is_empty() {
            path.push((indent, key));
        } else {
            let mut full: Vec<&str> = path.iter().map(|(_, k)| k.as_str()).collect();
            full.push(&key);
            flat.insert(full.join("."), unquote(v));
        }
    }
    flat
}

fn alacritty_yaml(text: &str, fallback_name: &str) -> Result<Palette, String> {
    alacritty_from(&yaml_flat(text), fallback_name)
}

// ---- base16 / base24 -------------------------------------------------------

fn base16(text: &str, fallback_name: &str) -> Result<Palette, String> {
    let flat = yaml_flat(text);
    let base = |n: &str| -> Option<Rgb> {
        flat.get(n)
            .or_else(|| flat.get(&format!("palette.{n}")))
            .and_then(|v| parse_hex(v))
    };
    let need = |n: &str| base(n).ok_or_else(|| format!("no {n} in the file"));
    let name = flat
        .get("scheme")
        .or_else(|| flat.get("name"))
        .cloned()
        .unwrap_or_else(|| fallback_name.to_string());
    let b00 = need("base00")?;
    let b05 = need("base05")?;
    let mut p = Parts::new(name, b05, b00);
    p.cursor = base("base05");
    p.cursor_text = Some(b00);
    p.selection = base("base02");
    let normal = [
        "base00", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base05",
    ];
    // base24 names the bright set; base16 reuses the normal colours, with
    // bright black and bright white taken from the greys.
    let bright = [
        "base03", "base12", "base14", "base13", "base16", "base17", "base15", "base07",
    ];
    let bright16 = [
        "base03", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base07",
    ];
    for i in 0..8 {
        p.ansi[i] = Some(need(normal[i])?);
        p.ansi[i + 8] = Some(match base(bright[i]) {
            Some(c) => c,
            None => need(bright16[i])?,
        });
    }
    p.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn iterm_fixture() -> String {
        let mut s = String::from(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n",
        );
        let entry = |name: &str, r: f64, g: f64, b: f64| {
            format!(
                "\t<key>{name}</key>\n\t<dict>\n\t\t<key>Color Space</key>\n\t\t<string>sRGB</string>\n\t\t<key>Blue Component</key>\n\t\t<real>{b}</real>\n\t\t<key>Green Component</key>\n\t\t<real>{g}</real>\n\t\t<key>Red Component</key>\n\t\t<real>{r}</real>\n\t</dict>\n"
            )
        };
        for i in 0..16 {
            s.push_str(&entry(
                &format!("Ansi {i} Color"),
                i as f64 / 15.0,
                0.5,
                0.25,
            ));
        }
        s.push_str(&entry("Background Color", 0.0, 0.0, 0.1));
        s.push_str(&entry("Foreground Color", 0.9, 0.9, 0.9));
        s.push_str(&entry("Cursor Color", 1.0, 0.0, 0.0));
        s.push_str(&entry("Selection Color", 0.2, 0.2, 0.5));
        s.push_str("</dict>\n</plist>\n");
        s
    }

    #[test]
    fn iterm2_colours_come_through() {
        let themes = parse(&iterm_fixture(), "solarized-dark.itermcolors").unwrap();
        let p = &themes[0];
        assert_eq!(p.name, "Solarized Dark");
        assert!(p.dark);
        assert_eq!(p.foreground, 0xE6E6E6);
        assert_eq!(p.background, 0x00001A);
        assert_eq!(p.cursor, 0xFF0000);
        assert_eq!(p.selection, 0x333380);
        assert_eq!(p.ansi[0], 0x008040);
        assert_eq!(p.ansi[15], 0xFF8040);
    }

    #[test]
    fn windows_terminal_schemes_one_or_many() {
        let one = r##"{
            "name": "Campbell",
            "black": "#0C0C0C", "red": "#C50F1F", "green": "#13A10E", "yellow": "#C19C00",
            "blue": "#0037DA", "purple": "#881798", "cyan": "#3A96DD", "white": "#CCCCCC",
            "brightBlack": "#767676", "brightRed": "#E74856", "brightGreen": "#16C60C",
            "brightYellow": "#F9F1A5", "brightBlue": "#3B78FF", "brightPurple": "#B4009E",
            "brightCyan": "#61D6D6", "brightWhite": "#F2F2F2",
            "background": "#0C0C0C", "foreground": "#CCCCCC",
            "cursorColor": "#FFFFFF", "selectionBackground": "#FFFFFF"
        }"##;
        let p = &parse(one, "campbell.json").unwrap()[0];
        assert_eq!(p.name, "Campbell");
        assert_eq!(p.ansi[5], 0x881798);
        assert_eq!(p.ansi[13], 0xB4009E);
        assert_eq!(p.cursor, 0xFFFFFF);

        let settings = format!(r#"{{ "defaultProfile": "x", "schemes": [{one}, {one}] }}"#);
        assert_eq!(parse(&settings, "settings.json").unwrap().len(), 2);

        let missing = one.replace("\"brightCyan\": \"#61D6D6\",", "");
        assert!(parse(&missing, "c.json")
            .unwrap_err()
            .contains("bright cyan"));
    }

    #[test]
    fn alacritty_toml_and_yaml_agree() {
        let toml = r##"
# Tomorrow Night
[colors.primary]
background = "#1d1f21"
foreground = '#c5c8c6'

[colors.cursor]
text = "#1d1f21"
cursor = "#c5c8c6"

[colors.normal]
black = "#1d1f21"
red = "#cc6666"
green = "#b5bd68"
yellow = "#f0c674"
blue = "#81a2be"
magenta = "#b294bb"
cyan = "#8abeb7"
white = "#c5c8c6"

[colors.bright]
black = "#969896"
red = "#cc6666"
green = "#b5bd68"
yellow = "#f0c674"
blue = "#81a2be"
magenta = "#b294bb"
cyan = "#8abeb7"
white = "#ffffff"
"##;
        let yaml = r##"
colors:
  primary:
    background: '#1d1f21'   # the same colour, hash style
    foreground: "#c5c8c6"
  cursor:
    text: '0x1d1f21'
    cursor: '0xc5c8c6'
  normal:
    black:   '0x1d1f21'
    red:     '0xcc6666'
    green:   '0xb5bd68'
    yellow:  '0xf0c674'
    blue:    '0x81a2be'
    magenta: '0xb294bb'
    cyan:    '0x8abeb7'
    white:   '0xc5c8c6'
  bright:
    black:   '0x969896'
    red:     '0xcc6666'
    green:   '0xb5bd68'
    yellow:  '0xf0c674'
    blue:    '0x81a2be'
    magenta: '0xb294bb'
    cyan:    '0x8abeb7'
    white:   '0xffffff'
"##;
        let a = &parse(toml, "tomorrow_night.toml").unwrap()[0];
        let b = &parse(yaml, "tomorrow_night.yml").unwrap()[0];
        assert_eq!(a.name, "Tomorrow Night");
        assert_eq!(a.ansi, b.ansi);
        assert_eq!(a.background, 0x1D1F21);
        assert_eq!(a.cursor, 0xC5C8C6);
        assert_eq!(
            a.selection, b.selection,
            "both derive the same selection colour"
        );

        // The inline-table form older configs use.
        let inline = "colors.primary = { background = \"#000000\", foreground = \"#ffffff\" }\n".to_string()
            + "colors.normal = { black = \"#000000\", red = \"#ff0000\", green = \"#00ff00\", yellow = \"#ffff00\", blue = \"#0000ff\", magenta = \"#ff00ff\", cyan = \"#00ffff\", white = \"#ffffff\" }\n"
            + "colors.bright = { black = \"#555555\", red = \"#ff5555\", green = \"#55ff55\", yellow = \"#ffff55\", blue = \"#5555ff\", magenta = \"#ff55ff\", cyan = \"#55ffff\", white = \"#ffffff\" }\n";
        let c = &parse(&inline, "mine.toml").unwrap()[0];
        assert_eq!(c.ansi[9], 0xFF5555);
    }

    #[test]
    fn base16_maps_the_standard_slots() {
        let yaml = r#"
scheme: "Default Dark"
author: "Chris Kempson"
base00: "181818"
base01: "282828"
base02: "383838"
base03: "585858"
base04: "b8b8b8"
base05: "d8d8d8"
base06: "e8e8e8"
base07: "f8f8f8"
base08: "ab4642"
base09: "dc9656"
base0A: "f7ca88"
base0B: "a1b56c"
base0C: "86c1b9"
base0D: "7cafc2"
base0E: "ba8baf"
base0F: "a16946"
"#;
        let p = &parse(yaml, "default-dark.yaml").unwrap()[0];
        assert_eq!(p.name, "Default Dark");
        assert_eq!(p.background, 0x181818);
        assert_eq!(p.foreground, 0xD8D8D8);
        assert_eq!(p.ansi[1], 0xAB4642);
        assert_eq!(p.ansi[8], 0x585858);
        assert_eq!(p.ansi[9], 0xAB4642, "base16 reuses red for bright red");
        assert_eq!(p.ansi[15], 0xF8F8F8);
        assert_eq!(p.selection, 0x383838);
        assert!(p.dark);
    }

    #[test]
    fn unknown_text_is_refused_kindly() {
        let err = parse("hello world", "notes.txt").unwrap_err();
        assert!(err.contains("iTerm2"), "{err}");
        assert_eq!(parse_hex("#abc"), Some(0xAABBCC));
        assert_eq!(parse_hex("0x1d1f21"), Some(0x1D1F21));
        assert_eq!(parse_hex("'#ffffff'"), Some(0xFFFFFF));
    }
}
