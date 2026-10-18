import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/clipboard.dart';

void main() {
  /// A clipboard that, like Android 10 and later, can't be read while the app
  /// is away: reads give nothing, or fail.
  String? copied;
  var readable = true;
  var failWhenAway = false;

  setUp(() {
    copied = null;
    readable = true;
    failWhenAway = false;
  });

  void fakeClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') {
        if (readable) return {'text': copied};
        if (failWhenAway) throw PlatformException(code: 'denied');
        return null;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void away(WidgetTester tester) {
    readable = false;
    lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
  }

  void back(WidgetTester tester) {
    readable = true;
    lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
  }

  testWidgets('a secret left on the clipboard while away is taken off on return', (tester) async {
    fakeClipboard(tester);
    await copySecret('recovery-code');
    away(tester);
    await tester.pump(secretClipboardTime);
    expect(copied, 'recovery-code', reason: 'the clipboard could not be read while away');

    back(tester);
    await tester.pump();
    expect(copied, '');
  });

  testWidgets('a failed read while away is retried on return too', (tester) async {
    fakeClipboard(tester);
    failWhenAway = true;
    await copySecret('private-key');
    away(tester);
    await tester.pump(secretClipboardTime);
    expect(copied, 'private-key');

    back(tester);
    await tester.pump();
    expect(copied, '');
  });

  testWidgets('something copied over the secret while away is kept', (tester) async {
    fakeClipboard(tester);
    await copySecret('join-code');
    away(tester);
    await tester.pump(secretClipboardTime);
    copied = 'something else';

    back(tester);
    await tester.pump();
    expect(copied, 'something else');
  });

  testWidgets('coming back before the minute is up leaves the secret until then', (tester) async {
    fakeClipboard(tester);
    await copySecret('recovery-code');
    away(tester);
    back(tester);
    await tester.pump();
    expect(copied, 'recovery-code');

    await tester.pump(secretClipboardTime);
    expect(copied, '');
  });
}
