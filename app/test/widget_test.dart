import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/app.dart';
import 'package:promptly/core/engine/engine.dart';

/// A stand-in for the Rust engine so widget tests need no native library.
class FakeEngine implements Engine {
  @override
  String version() => '9.9.9-test';

  @override
  String ping(String name) => 'pong: $name';

  @override
  EndpointParse parseEndpoint(String input) {
    final at = input.indexOf('@');
    if (at <= 0) return const EndpointError('a user name is required, like user@host');
    return EndpointOk(user: input.substring(0, at), host: input.substring(at + 1), port: 22);
  }

  @override
  int terminalOpenLocal({required int cols, required int rows, required bool dark}) => 1;
  @override
  Stream<TerminalEvent> terminalEvents(int id) => const Stream.empty();
  @override
  void terminalWrite(int id, List<int> data) {}
  @override
  void terminalPaste(int id, String text) {}
  @override
  void terminalResize(int id, int cols, int rows) {}
  @override
  void terminalScroll(int id, int delta) {}
  @override
  void terminalScrollToBottom(int id) {}
  @override
  void terminalSetDark(int id, bool dark) {}
  @override
  void terminalRefresh(int id) {}
  @override
  void terminalClose(int id) {}
}

Widget app() => ProviderScope(
      overrides: [engineProvider.overrideWithValue(FakeEngine())],
      child: const PromptlyApp(),
    );

void main() {
  testWidgets('shell shows the five tabs and starts on Hosts', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    for (final label in ['Hosts', 'Sessions', 'Snippets', 'Keys', 'Settings']) {
      expect(find.text(label), findsWidgets, reason: 'tab $label');
    }
    expect(find.text('No hosts yet'), findsOneWidget);
  });

  testWidgets('quick connect field asks the engine to parse user@host', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'deploy@web-1');
    await tester.pumpAndSettle();
    expect(find.text('Connect to deploy@web-1'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '@nobody');
    await tester.pumpAndSettle();
    expect(find.textContaining('user name is required'), findsOneWidget);
  });

  testWidgets('settings pings the engine and shows the reply', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Rust engine 9.9.9-test'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ping-input')), 'Ada');
    await tester.tap(find.text('Ping'));
    await tester.pumpAndSettle();
    expect(find.text('pong: Ada'), findsOneWidget);
  });

  testWidgets('theme can be switched to dark', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);
  });
}
