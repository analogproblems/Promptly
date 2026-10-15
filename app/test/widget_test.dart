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
  int generated = 0;

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
  @override
  void setDataDir(String path) {}
  @override
  int sshConnectBegin(SshConnectRequest request) => 1;
  @override
  Stream<SshEvent> sshConnectEvents(int attemptId) => const Stream.empty();
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
  String? settingGet(String key) => null;
  @override
  void settingSet(String key, String json) {}
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
}
