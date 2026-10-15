import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/app.dart';
import 'package:promptly/core/engine/engine.dart';

/// A stand-in for the Rust engine so widget tests need no native library.
/// Records and secrets live in maps so the hosts and keys screens work.
class FakeEngine implements Engine {
  final Map<String, Map<String, String>> records = {};
  final Map<String, String> secrets = {};
  final Map<String, String> settings = {};
  int generated = 0;

  /// Theme ids sessions were opened with, and "id theme" for later changes.
  final List<String> openedThemes = [];
  final List<String> themeCalls = [];

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
  int terminalOpenLocal({required int cols, required int rows, required String theme}) {
    openedThemes.add(theme);
    return 1;
  }
  @override
  Stream<TerminalEvent> terminalEvents(int id) {
    if (id != connectedSessionId) return const Stream.empty();
    final rows = <TerminalRow>[
      for (var y = 0; y < frameRows; y++)
        TerminalRow(
          line: y,
          glyphs: List.filled(frameCols, ''),
          fg: Uint32List(frameCols),
          bg: Uint32List(frameCols),
          flags: Uint16List(frameCols),
        ),
    ];
    return Stream.fromIterable([
      TerminalEvent(
        kind: TerminalEventKind.frame,
        frame: TerminalFrame(
          cols: frameCols,
          rows: frameRows,
          full: true,
          rowsChanged: rows,
          cursor: const TerminalCursor(line: 0, col: 0, shape: TerminalCursorShape.block),
          displayOffset: 0,
          historyLen: 0,
          defaultFg: 0xE6EDF3,
          defaultBg: 0x0E1116,
          cursorColor: 0x7CE38B,
          title: 'deploy@web-1: ~',
          bell: false,
          appCursor: false,
          altScreen: false,
          bracketedPaste: false,
          mouseReporting: false,
        ),
        clipboard: null,
        exitCode: null,
      ),
    ]);
  }
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
  void terminalSetTheme(int id, String theme) => themeCalls.add('$id $theme');
  @override
  void terminalRefresh(int id) {}
  @override
  void terminalSelectBegin(int id, int col, int line, bool sideRight, TerminalSelectKind kind) {}
  @override
  void terminalSelectUpdate(int id, int col, int line, bool sideRight) {}
  @override
  void terminalSelectClear(int id) {}
  @override
  String? terminalSelectionText(int id) => null;
  @override
  void terminalClose(int id) {}
  @override
  void setDataDir(String path) {}

  static ThemeInfo _theme(String id, String name, bool dark, int bg, int fg) => ThemeInfo(
        id: id,
        name: name,
        dark: dark,
        foreground: fg,
        background: bg,
        cursor: fg,
        selection: 0x444444,
        ansi: Uint32List.fromList(List.generate(16, (i) => 0x0F0F0F * (i + 1))),
      );

  @override
  List<ThemeInfo> themesList() => [
        _theme('promptly-dark', 'Promptly Dark', true, 0x0E1116, 0xE6EDF3),
        _theme('promptly-light', 'Promptly Light', false, 0xFAFAF7, 0x1F2328),
        _theme('dracula', 'Dracula', true, 0x282A36, 0xF8F8F2),
      ];

  /// When set, SSH attempts succeed with this engine session id, and that
  /// session emits one full frame of the given size.
  int? connectedSessionId;
  int frameCols = 142;
  int frameRows = 37;

  @override
  int sshConnectBegin(SshConnectRequest request) => 1;
  @override
  Stream<SshEvent> sshConnectEvents(int attemptId) {
    final id = connectedSessionId;
    if (id == null) return const Stream.empty();
    return Stream.fromIterable([
      const SshEvent(kind: SshEventKind.progress, step: SshStep.connecting, hostKey: null, secretPrompt: null, kbName: null, kbInstructions: null, kbPrompts: null, sessionId: null, error: null),
      SshEvent(kind: SshEventKind.connected, step: null, hostKey: null, secretPrompt: null, kbName: null, kbInstructions: null, kbPrompts: null, sessionId: id, error: null),
    ]);
  }
  @override
  void sshAnswerHostKey(int attemptId, bool trust) {}
  @override
  void sshAnswerSecret(int attemptId, String? secret) {}
  @override
  void sshAnswerKeyboardInteractive(int attemptId, List<String>? answers) {}
  @override
  void sshCancel(int attemptId) {}

  @override
  List<StoreRecord> recordsList(String collection) => [
        for (final e in (records[collection] ?? {}).entries)
          StoreRecord(id: e.key, json: e.value, updatedAt: ''),
      ];
  @override
  StoreRecord? recordGet(String collection, String id) {
    final json = records[collection]?[id];
    return json == null ? null : StoreRecord(id: id, json: json, updatedAt: '');
  }

  @override
  void recordPut(String collection, String id, String json) =>
      (records[collection] ??= {})[id] = json;
  @override
  bool recordDelete(String collection, String id) => (records[collection] ?? {}).remove(id) != null;
  @override
  String? settingGet(String key) => settings[key];
  @override
  void settingSet(String key, String json) => settings[key] = json;
  @override
  void secretPut(String id, String value) => secrets[id] = value;
  @override
  String? secretGet(String id) => secrets[id];
  @override
  void secretDelete(String id) => secrets.remove(id);
  @override
  GeneratedKey keyGenerate(SshKeyKind kind, String comment) {
    generated++;
    return GeneratedKey(
      kind: 'ed25519',
      privateOpenssh: '-----BEGIN OPENSSH PRIVATE KEY-----\nfake$generated\n-----END OPENSSH PRIVATE KEY-----',
      publicOpenssh: 'ssh-ed25519 AAAAfake$generated $comment',
      fingerprint: 'SHA256:fake$generated',
    );
  }

  @override
  KeyInfo keyInspect(String privateKey, String? passphrase) => const KeyInfo(
        kind: 'ed25519',
        publicOpenssh: 'ssh-ed25519 AAAAimported',
        fingerprint: 'SHA256:imported',
        encrypted: false,
        comment: '',
      );
  @override
  String keyFingerprint(String publicKey) => 'SHA256:${publicKey.hashCode}';
}

Widget app([FakeEngine? engine]) => ProviderScope(
      overrides: [engineProvider.overrideWithValue(engine ?? FakeEngine())],
      child: const PromptlyApp(),
    );

String hostJson(String id, String label, {String? group}) =>
    '{"id":"$id","label":"$label","hostname":"$label.example","port":22,"username":"ops",'
    '"auth":{"kind":"interactive"},"group_id":${group == null ? 'null' : '"$group"'},"tags":[],"color":null,'
    '"icon":null,"notes":"","jump_host_id":null,"keepalive_seconds":30,"startup_command":null,"env":{},'
    '"persistent_session":false,"port_forwards":[],"last_connected_at":null,"favourite":false,"sync":"vault"}';

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

  testWidgets('theme can be switched to dark and is remembered for the next start', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    var materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);
    expect(engine.settings['theme_mode'], '"dark"');

    // A fresh app on the same store starts dark.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.dark);
  });

  testWidgets('picking a terminal theme saves it and recolours open sessions', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 1;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local shell'));
    await tester.pumpAndSettle();
    expect(engine.openedThemes, ['promptly-light'], reason: 'auto follows the light app look');

    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Matches the app · Promptly Light'), findsOneWidget);
    await tester.tap(find.byKey(const Key('terminal-theme')));
    await tester.pumpAndSettle();
    expect(find.text('Terminal theme'), findsOneWidget);
    await tester.tap(find.byKey(const Key('theme-dracula')));
    await tester.pumpAndSettle();
    expect(engine.settings['terminal_theme'], '"dracula"');
    expect(engine.themeCalls, contains('1 dracula'), reason: 'the open session is recoloured');

    // Back on settings the row names the pick; a new shell opens with it.
    await tester.tap(find.byTooltip('Back to settings'));
    await tester.pumpAndSettle();
    expect(find.text('Dracula'), findsOneWidget);
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to sessions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local shell').first);
    await tester.pumpAndSettle();
    expect(engine.openedThemes.last, 'dracula');
  });

  testWidgets('saved hosts show grouped, searchable, with the ungrouped under Other', (tester) async {
    final engine = FakeEngine();
    engine.records['groups'] = {
      'g1': '{"id":"g1","label":"Production","parent_id":null,"color":null,"defaults":{}}',
    };
    engine.records['hosts'] = {
      'h1': hostJson('h1', 'web-1', group: 'g1'),
      'h2': hostJson('h2', 'nas'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.text('PRODUCTION'), findsOneWidget);
    expect(find.text('OTHER'), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('nas'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'web');
    await tester.pumpAndSettle();
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('nas'), findsNothing);
  });

  testWidgets('the host editor saves a new host into the store', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add host'));
    await tester.pumpAndSettle();
    expect(find.text('New host'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('host-label')), 'db-primary');
    await tester.enterText(find.byKey(const Key('host-hostname')), '10.0.0.20');
    await tester.enterText(find.byKey(const Key('host-username')), 'postgres');
    await tester.tap(find.byKey(const Key('host-save')));
    await tester.pumpAndSettle();
    expect(engine.records['hosts']?.length, 1);
    expect(engine.records['hosts']!.values.first, contains('"hostname":"10.0.0.20"'));
    expect(find.text('db-primary'), findsOneWidget);
    expect(find.textContaining('postgres@10.0.0.20'), findsOneWidget);
  });

  testWidgets('generating a key stores the private half as a secret', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keys').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('keys-generate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('key-label')), 'laptop');
    await tester.tap(find.byKey(const Key('key-generate-ok')));
    await tester.pumpAndSettle();
    expect(engine.generated, 1);
    expect(engine.records['identities']?.length, 1);
    expect(engine.secrets.length, 1);
    expect(engine.secrets.values.first, contains('OPENSSH PRIVATE KEY'));
    expect(engine.secrets.keys.first, matches(RegExp(r'^[0-9a-f-]{36}$')), reason: 'secret ids are UUIDs');
    expect(find.text('laptop'), findsOneWidget);
  });

  testWidgets('an SSH session that connects after the screen opened shows its live size and title', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'deploy@web-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    // The connecting screen is up first; the session arrives from the stream afterwards.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('142×37'), findsOneWidget, reason: 'the title bar must follow the live grid');
    expect(find.text('deploy@web-1: ~'), findsOneWidget, reason: 'and the title the program set');
  });
}
