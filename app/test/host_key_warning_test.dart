import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/features/sessions/host_key_warning.dart';

const _key = SshHostKey(
  host: 'web-1.example',
  port: 22,
  algorithm: 'ED25519',
  bits: 256,
  fingerprint: 'SHA256:abc',
  publicKey: 'ssh-ed25519 AAAA',
  randomart: '+--[ED25519 256]--+',
  status: SshHostKeyStatus.changed,
);

void main() {
  Future<List<bool>> pump(WidgetTester tester, {double textScale = 1}) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: ChangedHostKeyPanel(hostKey: _key, onAnswer: answers.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return answers;
  }

  testWidgets('a changed key opens a full-screen warning where leaving is the default', (tester) async {
    final answers = await pump(tester);
    expect(find.byType(HostKeyChangedPage), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  testWidgets('trusting takes opening the override and ticking the check', (tester) async {
    final answers = await pump(tester);
    expect(find.byKey(const Key('hostkey-trust')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('hostkey-override')));
    await tester.tap(find.byKey(const Key('hostkey-override')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('hostkey-trust')));
    await tester.tap(find.byKey(const Key('hostkey-trust')));
    await tester.pumpAndSettle();
    expect(answers, isEmpty, reason: 'disabled until the box is ticked');
    await tester.ensureVisible(find.byKey(const Key('hostkey-checked')));
    await tester.tap(find.byKey(const Key('hostkey-checked')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hostkey-trust')));
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('back means disconnect', (tester) async {
    final answers = await pump(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(answers, [false]);
    expect(find.byType(HostKeyChangedPage), findsNothing);
  });

  testWidgets('Escape means disconnect', (tester) async {
    final answers = await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(answers, [false]);
    expect(find.byType(HostKeyChangedPage), findsNothing);
  });

  testWidgets('the warning fits a phone at double text size, override included', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final answers = await pump(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('hostkey-override')));
    await tester.tap(find.byKey(const Key('hostkey-override')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('hostkey-checked')));
    await tester.tap(find.byKey(const Key('hostkey-checked')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('hostkey-trust')));
    await tester.tap(find.byKey(const Key('hostkey-trust')));
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });
}
