import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/features/terminal/key_mapper.dart';

KeyDownEvent down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );

void main() {
  test('printable characters pass through as UTF-8', () {
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.keyA, character: 'a'), appCursor: false), [0x61]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.keyA, character: 'é'), appCursor: false), [0xc3, 0xa9]);
  });

  test('special keys send the right sequences', () {
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.enter), appCursor: false), [0x0d]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.backspace), appCursor: false), [0x7f]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.escape), appCursor: false), [0x1b]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.tab), appCursor: false), [0x09]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.delete), appCursor: false), [0x1b, 0x5b, 0x33, 0x7e]);
  });

  test('arrows follow application cursor mode', () {
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.arrowUp), appCursor: false), [0x1b, 0x5b, 0x41]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.arrowUp), appCursor: true), [0x1b, 0x4f, 0x41]);
    // With a modifier the xterm form is used in both modes.
    expect(
      KeyMapper.bytesFor(down(LogicalKeyboardKey.arrowLeft), appCursor: true, ctrl: true),
      '\x1b[1;5D'.codeUnits,
    );
  });

  test('control and alt combinations', () {
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.keyC), appCursor: false, ctrl: true), [0x03]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.keyZ), appCursor: false, ctrl: true), [0x1a]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.bracketLeft), appCursor: false, ctrl: true), [0x1b]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.keyB, character: 'b'), appCursor: false, alt: true), [0x1b, 0x62]);
  });

  test('Alt goes in front of Enter, Backspace, Tab and Escape too', () {
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.backspace), appCursor: false, alt: true), [0x1b, 0x7f]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.enter), appCursor: false, alt: true), [0x1b, 0x0d]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.tab), appCursor: false, alt: true), [0x1b, 0x09]);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.escape), appCursor: false, alt: true), [0x1b, 0x1b]);
    // Keys with a modifier form keep it rather than taking an ESC.
    expect(
      KeyMapper.bytesFor(down(LogicalKeyboardKey.arrowLeft), appCursor: false, alt: true),
      '\x1b[1;3D'.codeUnits,
    );
  });

  test('app shortcuts are left to the app', () {
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.keyV), appCursor: false, ctrl: true, shift: true), isNull);
    expect(KeyMapper.bytesFor(down(LogicalKeyboardKey.pageUp), appCursor: false, shift: true), isNull);
    final up = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    );
    expect(KeyMapper.bytesFor(up, appCursor: false), isNull);
  });

  test('Caps Lock can type Escape, and then letters follow Shift alone', () {
    final caps = down(LogicalKeyboardKey.capsLock);
    expect(KeyMapper.bytesFor(caps, appCursor: false), isNull, reason: 'off, Caps Lock is left to the system');
    expect(KeyMapper.bytesFor(caps, appCursor: false, capsLockAsEscape: true), [0x1b]);
    // The system still turns Caps Lock on, so its capitals are undone.
    final a = down(LogicalKeyboardKey.keyA, character: 'A');
    expect(KeyMapper.bytesFor(a, appCursor: false, capsLockAsEscape: true, capsLocked: true), [0x61]);
    expect(
      KeyMapper.bytesFor(a, appCursor: false, capsLockAsEscape: true, capsLocked: true, shift: true),
      [0x41],
      reason: 'Shift still makes a capital',
    );
    expect(KeyMapper.bytesFor(a, appCursor: false, capsLocked: true), [0x41], reason: 'without the option, as typed');
    final bang = down(LogicalKeyboardKey.exclamation, character: '!');
    expect(KeyMapper.bytesFor(bang, appCursor: false, capsLockAsEscape: true, capsLocked: true), [0x21]);
  });
}
