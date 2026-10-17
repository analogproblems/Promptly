import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/features/terminal/paste_guard.dart';

void main() {
  test('describes lines and a final newline', () {
    expect(describePaste('ls'), (lines: 1, endsWithNewline: false));
    expect(describePaste('ls\n'), (lines: 1, endsWithNewline: true));
    expect(describePaste('a\r\nb\r\nc'), (lines: 3, endsWithNewline: false));
    expect(pasteNeedsConfirm('one line'), isFalse);
    expect(pasteNeedsConfirm('rm -rf build\n'), isTrue);
    expect(withoutFinalNewline('a\nb\r\n'), 'a\nb');
  });

  Future<String?> pasteThrough(WidgetTester tester, String text, {String? tap}) async {
    String? result = 'untouched';
    await tester.pumpWidget(MaterialApp(
      theme: buildPromptlyTheme(Brightness.dark),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await confirmPaste(context, text, warn: true),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    if (tap != null) {
      await tester.tap(find.byKey(Key(tap)));
      await tester.pumpAndSettle();
    }
    return result;
  }

  testWidgets('one line goes straight through', (tester) async {
    expect(await pasteThrough(tester, 'echo hi'), 'echo hi');
  });

  testWidgets('several lines are shown first, and can lose the final newline', (tester) async {
    expect(await pasteThrough(tester, 'a\nb\n', tap: 'paste-no-newline'), 'a\nb');
  });

  testWidgets('pasting as it is keeps every newline', (tester) async {
    expect(await pasteThrough(tester, 'a\nb\n', tap: 'paste-confirm'), 'a\nb\n');
  });

  testWidgets('cancel pastes nothing, and with the warning off nothing is asked', (tester) async {
    expect(await pasteThrough(tester, 'a\nb', tap: null), 'untouched', reason: 'still waiting');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    String? off = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => off = await confirmPaste(context, 'a\nb', warn: false),
          child: const Text('off'),
        ),
      ),
    ));
    await tester.tap(find.text('off'));
    await tester.pumpAndSettle();
    expect(off, 'a\nb');
  });

  testWidgets('the sheet fits at double text size on a phone', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? result = 'x';
    await tester.pumpWidget(MaterialApp(
      theme: buildPromptlyTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await confirmPaste(context, 'one\ntwo\n', warn: true),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
