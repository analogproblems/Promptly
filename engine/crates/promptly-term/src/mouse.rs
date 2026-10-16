//! Mouse events for programs that ask for them (vim with `mouse=a`, tmux,
//! htop): xterm's encodings, chosen by the modes the program set.

use alacritty_terminal::term::TermMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Middle,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press(MouseButton),
    Release(MouseButton),
    /// The pointer moved, with this button held or none.
    Move(Option<MouseButton>),
    WheelUp,
    WheelDown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MouseEvent {
    pub action: MouseAction,
    /// Zero-based cell on the visible screen.
    pub col: u16,
    pub row: u16,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

fn button_code(b: MouseButton) -> u32 {
    match b {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    }
}

/// The bytes to send for `event`, or `None` when the program has not asked
/// for this kind of event.
pub fn encode(mode: TermMode, event: MouseEvent) -> Option<Vec<u8>> {
    let clicks = mode.intersects(TermMode::MOUSE_MODE);
    let (mut code, release) = match event.action {
        MouseAction::Press(b) if clicks => (button_code(b), false),
        MouseAction::Release(b) if clicks => (button_code(b), true),
        MouseAction::WheelUp if clicks => (64, false),
        MouseAction::WheelDown if clicks => (65, false),
        MouseAction::Move(Some(b))
            if mode.intersects(TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION) =>
        {
            (32 + button_code(b), false)
        }
        MouseAction::Move(None) if mode.contains(TermMode::MOUSE_MOTION) => (32 + 3, false),
        _ => return None,
    };
    if event.shift {
        code += 4;
    }
    if event.alt {
        code += 8;
    }
    if event.ctrl {
        code += 16;
    }
    let x = u32::from(event.col) + 1;
    let y = u32::from(event.row) + 1;

    if mode.contains(TermMode::SGR_MOUSE) {
        let end = if release { 'm' } else { 'M' };
        return Some(format!("\x1b[<{code};{x};{y}{end}").into_bytes());
    }
    // The older encoding: a release does not say which button.
    if release {
        code = (code & !3) | 3;
    }
    let mut out = b"\x1b[M".to_vec();
    out.push((32 + code) as u8);
    for v in [x, y] {
        if mode.contains(TermMode::UTF8_MOUSE) {
            let c = char::from_u32(32 + v.min(2015))?;
            let mut buf = [0u8; 4];
            out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        } else {
            // One byte per coordinate: past column 223 it cannot be said.
            out.push((32 + v.min(223)) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(action: MouseAction, col: u16, row: u16) -> MouseEvent {
        MouseEvent {
            action,
            col,
            row,
            shift: false,
            alt: false,
            ctrl: false,
        }
    }

    #[test]
    fn nothing_is_sent_unless_asked_for() {
        let click = ev(MouseAction::Press(MouseButton::Left), 0, 0);
        assert_eq!(encode(TermMode::empty(), click), None);
        let drag = ev(MouseAction::Move(Some(MouseButton::Left)), 1, 1);
        assert_eq!(encode(TermMode::MOUSE_REPORT_CLICK, drag), None);
        let hover = ev(MouseAction::Move(None), 1, 1);
        assert_eq!(encode(TermMode::MOUSE_DRAG, hover), None);
        assert_eq!(encode(TermMode::MOUSE_REPORT_CLICK, hover), None);
    }

    #[test]
    fn sgr_encoding() {
        let mode = TermMode::MOUSE_DRAG | TermMode::SGR_MOUSE;
        let at = |a| encode(mode, ev(a, 4, 9)).unwrap();
        assert_eq!(at(MouseAction::Press(MouseButton::Left)), b"\x1b[<0;5;10M");
        assert_eq!(
            at(MouseAction::Release(MouseButton::Left)),
            b"\x1b[<0;5;10m"
        );
        assert_eq!(
            at(MouseAction::Move(Some(MouseButton::Left))),
            b"\x1b[<32;5;10M"
        );
        assert_eq!(at(MouseAction::WheelDown), b"\x1b[<65;5;10M");
        let mut ctrl = ev(MouseAction::Press(MouseButton::Right), 0, 0);
        ctrl.ctrl = true;
        assert_eq!(encode(mode, ctrl).unwrap(), b"\x1b[<18;1;1M");
        // Any-motion mode also gets moves with no button held.
        let hover = ev(MouseAction::Move(None), 4, 9);
        let motion = TermMode::MOUSE_MOTION | TermMode::SGR_MOUSE;
        assert_eq!(encode(motion, hover).unwrap(), b"\x1b[<35;5;10M");
    }

    #[test]
    fn normal_encoding() {
        let mode = TermMode::MOUSE_REPORT_CLICK;
        let press = encode(mode, ev(MouseAction::Press(MouseButton::Middle), 0, 2)).unwrap();
        assert_eq!(press, b"\x1b[M\x21\x21\x23");
        let release = encode(mode, ev(MouseAction::Release(MouseButton::Middle), 0, 2)).unwrap();
        assert_eq!(release, b"\x1b[M\x23\x21\x23");
        let far = encode(mode, ev(MouseAction::Press(MouseButton::Left), 300, 0)).unwrap();
        assert_eq!(far[4], 255, "clamped to what one byte can carry");
        let utf8 = encode(
            mode | TermMode::UTF8_MOUSE,
            ev(MouseAction::Press(MouseButton::Left), 300, 0),
        )
        .unwrap();
        assert_eq!(&utf8[4..6], "ō".as_bytes(), "column 301 as U+014D");
    }
}
