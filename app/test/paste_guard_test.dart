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
}
