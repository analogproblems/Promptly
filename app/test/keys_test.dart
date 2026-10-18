import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/features/hosts/models.dart';
import 'package:promptly/features/hosts/repositories.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app_lock_test.dart' show FakeAuthenticator;
import 'widget_test.dart' show FakeEngine, app, appWith, hostJson, scrollTap, tapVisible;

/// A key whose text is locked behind FakeEngine.lockedPassphrase, used by
/// host h1.
FakeEngine lockedKeyEngine({String? savedPassphrase}) {
  final engine = FakeEngine()..connectedSessionId = 7;
  engine.secrets['pk1'] = '-----BEGIN OPENSSH PRIVATE KEY-----\nLOCKED\n-----END OPENSSH PRIVATE KEY-----';
  if (savedPassphrase != null) engine.secrets['pp1'] = savedPassphrase;
  engine.records['identities'] = {
    'k1': jsonEncode({
      'id': 'k1',
      'label': 'laptop',
      'key_type': 'ed25519',
      'public_key': 'ssh-ed25519 AAAAlocked laptop',
      'private_key_secret_id': 'pk1',
      'hardware': null,
      'passphrase_secret_id': savedPassphrase == null ? null : 'pp1',
      'sync': 'vault',
    }),
  };
  engine.records['hosts'] = {'h1': hostJson('h1', 'web-1', auth: '{"kind":"identity","identity_id":"k1"}')};
  return engine;
}

Map<String, dynamic> identity(FakeEngine engine, String id) =>
    jsonDecode(engine.records['identities']![id]!) as Map<String, dynamic>;

Future<void> openKeyMenu(WidgetTester tester, String item) async {
  await tester.tap(find.text('Keys').first);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Key actions').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

Future<void> openSync(WidgetTester tester) async {
  await tester.tap(find.text('Settings').first);
  await tester.pumpAndSettle();
  await scrollTap(tester, find.text('Open'));
  await tester.pumpAndSettle();
}

/// Let a connection reach its question. Not settled: the step in progress
/// keeps spinning while it waits.
Future<void> asking(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets("a locked key's passphrase is asked once, saved with the key, reused, and can be forgotten", (tester) async {
    final engine = lockedKeyEngine()..askKeyPassphrase = true;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await asking(tester);
    expect(find.text('Passphrase for the private key'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('secret-remember'))).value, isTrue,
        reason: 'remembering is on unless turned off');

    // A wrong one is not kept; the engine asks again.
    await tester.enterText(find.byKey(const Key('secret-input')), 'nope');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(identity(engine, 'k1')['passphrase_secret_id'], isNull);

    // Connect again: this time with the right one.
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await asking(tester);
    engine.writes.clear();
    await tester.enterText(find.byKey(const Key('secret-input')), FakeEngine.lockedPassphrase);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    final secretId = identity(engine, 'k1')['passphrase_secret_id'] as String?;
    expect(secretId, isNotNull);
    expect(engine.secrets[secretId], FakeEngine.lockedPassphrase);
    expect(engine.writes.take(2), ['record identities', 'secret'], reason: 'the key says where its passphrase may go first');

    // The next connection brings it along and nothing is asked.
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    expect(engine.requests.last.passphrase, FakeEngine.lockedPassphrase);
    expect(engine.answeredSecrets, ['nope', FakeEngine.lockedPassphrase]);

    // Forgotten from the key's menu.
    await openKeyMenu(tester, 'Forget saved passphrase');
    expect(identity(engine, 'k1')['passphrase_secret_id'], isNull);
    expect(engine.secrets.containsKey(secretId), isFalse);
    expect(find.textContaining('is forgotten'), findsOneWidget);
  });

  testWidgets('a remembered passphrase goes to the key the host uses, not another copy of it', (tester) async {
    final engine = lockedKeyEngine()..askKeyPassphrase = true;
    // The same key imported twice: a copy listed first, kept in the vault,
    // and the host's own, kept on this device only.
    engine.secrets['pk0'] = engine.secrets['pk1']!;
    engine.records['identities']!['k0'] = jsonEncode({
      ...identity(engine, 'k1'),
      'id': 'k0',
      'label': 'a shared copy',
      'private_key_secret_id': 'pk0',
    });
    engine.records['identities']!['k1'] = jsonEncode({...identity(engine, 'k1'), 'sync': 'local_only'});
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await asking(tester);
    await tester.enterText(find.byKey(const Key('secret-input')), FakeEngine.lockedPassphrase);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(identity(engine, 'k1')['passphrase_secret_id'], isNotNull);
    expect(identity(engine, 'k0')['passphrase_secret_id'], isNull);
  });

  testWidgets('trying again after the host was given another key saves the passphrase on the key tried', (tester) async {
    final engine = lockedKeyEngine()
      ..failWith = const SshEvent(kind: SshEventKind.failed, secretForKey: false, error: 'nothing is listening there');
    engine.records['identities']!['k0'] = jsonEncode({...identity(engine, 'k1'), 'id': 'k0', 'label': 'other'});
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);

    // Meanwhile the host is switched to the other key.
    final hosts = ProviderScope.containerOf(tester.element(find.text('Try again'))).read(hostsProvider.notifier);
    hosts.save(hosts.byId('h1')!.copyWith(auth: const HostAuth(kind: AuthKind.identity, identityId: 'k0')));
    engine
      ..failWith = null
      ..askKeyPassphrase = true;
    await tester.tap(find.text('Try again'));
    await asking(tester);
    expect(engine.requests.last.privateKey, engine.secrets['pk1'], reason: 'the same request, with k1');
    await tester.enterText(find.byKey(const Key('secret-input')), FakeEngine.lockedPassphrase);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(identity(engine, 'k1')['passphrase_secret_id'], isNotNull);
    expect(identity(engine, 'k0')['passphrase_secret_id'], isNull);
  });

  testWidgets('with Remember passphrase off nothing is saved, but a reconnect does not ask again', (tester) async {
    final engine = lockedKeyEngine()
      ..askKeyPassphrase = true
      ..dropAfterFrame = true;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await asking(tester);
    await tester.tap(find.byKey(const Key('secret-remember')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('secret-input')), FakeEngine.lockedPassphrase);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Connection dropped'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(engine.requests.length, 2);
    expect(engine.requests.last.reattachSessionId, 7);
    expect(engine.requests.last.passphrase, FakeEngine.lockedPassphrase);
    expect(engine.answeredSecrets, [FakeEngine.lockedPassphrase], reason: 'asked once only');
    expect(identity(engine, 'k1')['passphrase_secret_id'], isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('a saved passphrase goes into snippets run on hosts too', (tester) async {
    final engine = lockedKeyEngine(savedPassphrase: FakeEngine.lockedPassphrase);
    engine.records['snippets'] = {
      's1': '{"id":"s1","label":"Uptime","command":"uptime","tags":[],"variables":[]}',
    };
    engine.execResults['web-1.example'] = const SshExecResult(output: 'up', exitCode: 0, timedOut: false, error: null);
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snippets').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Snippet actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run on hosts…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('run-select-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('run-on-hosts-go')));
    await tester.pumpAndSettle();
    expect(engine.execCalls, ['web-1.example uptime']);
    expect(find.textContaining('passphrase'), findsNothing);
  });

  testWidgets('an imported locked key keeps its passphrase when Remember is on', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keys').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('unless you keep a key on this device only'), findsOneWidget,
        reason: 'the empty screen says keys sync');
    expect(find.textContaining('stay on this device'), findsNothing);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'work');
    await tester.enterText(find.byKey(const Key('key-text')), '-----BEGIN OPENSSH PRIVATE KEY-----\nLOCKED\n-----END OPENSSH PRIVATE KEY-----');
    expect(find.byKey(const Key('key-import-remember')), findsNothing, reason: 'only once a passphrase is typed');
    await tester.enterText(find.byKey(const Key('key-import-passphrase')), FakeEngine.lockedPassphrase);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('key-import-remember'))).value, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    final saved = identity(engine, engine.records['identities']!.keys.single);
    expect(engine.secrets[saved['passphrase_secret_id']], FakeEngine.lockedPassphrase);
    expect(find.textContaining('passphrase saved'), findsOneWidget);
  });

  testWidgets('the public key shows as a QR code and can be copied from there', (tester) async {
    final engine = FakeEngine();
    engine.records['identities'] = {
      'k1': '{"id":"k1","label":"laptop","key_type":"ed25519","public_key":"ssh-ed25519 AAAApub laptop",'
          '"private_key_secret_id":"pk1","hardware":null,"passphrase_secret_id":null,"sync":"vault"}',
    };
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return {'text': copied};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openKeyMenu(tester, 'Show public key as QR code');
    expect(find.byKey(const Key('key-qr')), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Copy'));
    await tester.pumpAndSettle();
    expect(copied, 'ssh-ed25519 AAAApub laptop');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('Install on a host uses its saved login, or a password typed for one without', (tester) async {
    final engine = FakeEngine();
    engine.secrets['p1'] = 'hunter2';
    engine.records['hosts'] = {
      'h1': hostJson('h1', 'web-1', auth: '{"kind":"password","password_secret_id":"p1"}'),
      'h2': hostJson('h2', 'nas'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keys').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('keys-generate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('key-generate-ok')));
    await tester.pumpAndSettle();
    await openKeyMenu(tester, 'Install on a host…');
    expect(tester.widget<FilledButton>(find.byKey(const Key('install-go'))).onPressed, isNull,
        reason: 'a host is picked first');

    await tester.tap(find.byKey(const Key('install-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web-1 · ops@web-1.example').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('install-password')), findsNothing, reason: 'it has a saved password');
    await tester.tap(find.byKey(const Key('install-go')));
    await tester.pumpAndSettle();
    expect(engine.installCalls, ['web-1.example password hunter2 ssh-ed25519 AAAAfake1 promptly']);
    expect(find.text('Installed on web-1. It can log in with this key now.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('install-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('nas · ops@nas.example').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('install-go')));
    await tester.pumpAndSettle();
    expect(find.text('Type the password for nas.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('install-password')), 's3cret');
    await tester.tap(find.byKey(const Key('install-go')));
    await tester.pumpAndSettle();
    expect(engine.installCalls.last, 'nas.example password s3cret ssh-ed25519 AAAAfake1 promptly');
  });

  testWidgets('installing with a key login and exporting a key both wait for the key check', (tester) async {
    final engine = lockedKeyEngine(savedPassphrase: FakeEngine.lockedPassphrase);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final auth = FakeAuthenticator(answer: false);
    await tester.pumpWidget(appWith(engine, authenticator: auth));
    await tester.pumpAndSettle();

    // h1 logs in with the locked key: refused, so it never connects.
    await openKeyMenu(tester, 'Install on a host…');
    await tester.tap(find.byKey(const Key('install-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web-1 · ops@web-1.example').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('install-go')));
    await tester.pumpAndSettle();
    expect(auth.asked, ['Unlock your SSH key']);
    expect(engine.installCalls, isEmpty);
    expect(find.text('The SSH key for web-1 stays locked, so nothing was installed.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Refused: the private key is not shown at all.
    await openKeyMenu(tester, 'Export private key…');
    expect(find.textContaining('log in as you'), findsNothing);
    expect(find.text('The key stays locked, so it was not exported.'), findsOneWidget);
    expect(copied, isNull);

    // Passed: both go ahead.
    auth.answer = true;
    await openKeyMenu(tester, 'Export private key…');
    expect(find.textContaining('log in as you'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await openKeyMenu(tester, 'Install on a host…');
    await tester.tap(find.byKey(const Key('install-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web-1 · ops@web-1.example').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('install-go')));
    await tester.pumpAndSettle();
    expect(engine.installCalls, hasLength(1));
  });

  testWidgets('exporting the private key waits for the warning to be ticked, and can lock it anew', (tester) async {
    final engine = lockedKeyEngine();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return {'text': copied};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final saved = <String>[];
    await tester.pumpWidget(appWith(
      engine,
      fileSaver: ({required String suggestedName, required String text}) async {
        saved.add('$suggestedName: $text');
        return '/home/you/$suggestedName';
      },
    ));
    await tester.pumpAndSettle();
    await openKeyMenu(tester, 'Export private key…');
    expect(find.textContaining('log in as you'), findsOneWidget);
    expect(find.text('As stored, it is locked with its passphrase.'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('export-copy'))).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byKey(const Key('export-save'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('export-understood')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-copy')));
    await tester.pumpAndSettle();
    expect(copied, engine.secrets['pk1'], reason: 'as stored');

    // Locked anew: its passphrase now is needed, as none is saved.
    await openKeyMenu(tester, 'Export private key…');
    await tester.tap(find.byKey(const Key('export-understood')));
    await tester.tap(find.byKey(const Key('export-relock')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('export-current')), 'nope');
    await tester.enterText(find.byKey(const Key('export-new')), 'fresh one');
    await tester.enterText(find.byKey(const Key('export-again')), 'fresh one');
    await tester.tap(find.byKey(const Key('export-save')));
    await tester.pumpAndSettle();
    expect(find.text('That passphrase is wrong.'), findsOneWidget);
    expect(saved, isEmpty);
    await tester.enterText(find.byKey(const Key('export-current')), FakeEngine.lockedPassphrase);
    await tester.tap(find.byKey(const Key('export-save')));
    await tester.pumpAndSettle();
    expect(saved, ['laptop: RELOCKED with fresh one']);
    expect(find.text('Saved to /home/you/laptop.'), findsOneWidget);
    // The copied key leaves the clipboard after a minute.
    await tester.pump(const Duration(minutes: 1));
    expect(copied, '');
  });

  testWidgets('setup says twice that losing the passphrase and the recovery code loses the data', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.text('Set up'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('sync-continue')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-path')), '/tmp/vault');
    await tapVisible(tester, find.byKey(const Key('sync-folder-continue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-lose-both-passphrase')), findsOneWidget);
    expect(find.textContaining('the data in the vault is gone for good'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-passphrase')), 'correct horse battery');
    await tester.enterText(find.byKey(const Key('sync-passphrase-confirm')), 'correct horse battery');
    await tapVisible(tester, find.byKey(const Key('sync-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-lose-both-recovery')), findsOneWidget);
    expect(find.textContaining('the data in the vault is gone for good'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('sync-done'))).onPressed, isNull,
        reason: 'continuing waits for "I have written it down"');
  });

  testWidgets('the join code, re-keying and removing a device each ask first when a lock is on', (tester) async {
    final engine = FakeEngine()..configured();
    final auth = FakeAuthenticator(answer: false);
    await tester.pumpWidget(appWith(engine, authenticator: auth));
    await tester.pumpAndSettle();
    await openSync(tester);

    await tapVisible(tester, find.text('Show code'));
    await tester.pumpAndSettle();
    expect(auth.asked, ['Show the join code']);
    expect(find.byKey(const Key('join-code-view')), findsNothing, reason: 'refused, so not shown');

    await tapVisible(tester, find.byKey(const Key('sync-rekey')));
    await tester.pumpAndSettle();
    expect(auth.asked.last, 'Re-key the vault');
    expect(find.text('Re-key the vault'), findsOneWidget, reason: 'only the card; no passphrase asked');

    await tapVisible(tester, find.byTooltip('Remove device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-remove-confirm')));
    await tester.pumpAndSettle();
    expect(auth.asked.last, 'Remove Phone from the vault');
    expect(engine.syncCalls.where((c) => c.startsWith('remove')), isEmpty);

    auth.answer = true;
    await tapVisible(tester, find.text('Show code'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('join-code-view')), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
  });

  testWidgets('the join code shows over a dimmed screen for a minute, and hides when the app goes away', (tester) async {
    final engine = FakeEngine()..configured();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return {'text': copied};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);
    await tapVisible(tester, find.text('Show code'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('join-code-view')), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Closes in 60 s'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('join-code-copy')));
    await tester.pump();
    expect(copied, FakeEngine.syncQrText);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Closes in 30 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('join-code-view')), findsNothing, reason: 'closed by itself after a minute');
    expect(copied, '', reason: 'and the code left the clipboard too');

    await tapVisible(tester, find.text('Show code'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('join-code-view')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('join-code-view')), findsNothing, reason: 'hidden as the app leaves the front');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  });

  testWidgets('a new device joins with the join code pasted as text', (tester) async {
    final engine = FakeEngine()..foldersWithVaults.add('/shared/vault');
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.text('Set up'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('sync-continue')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-path')), '/shared/vault');
    await tapVisible(tester, find.byKey(const Key('sync-folder-continue')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('sync-join-with-joinCode')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Copy as text'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-join-code')), 'not it');
    await tapVisible(tester, find.byKey(const Key('sync-join')));
    await tester.pumpAndSettle();
    expect(find.text('That is not a join code.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-join-code')), '  ${FakeEngine.syncQrText}\n');
    await tapVisible(tester, find.byKey(const Key('sync-join')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls.last, 'join /shared/vault pass=null code=null join=${FakeEngine.syncQrText}');
    expect(find.byKey(const Key('sync-summary')), findsOneWidget, reason: 'joined');
  });

  testWidgets('the key dialogs and the join code fit a small phone at double text size', (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final engine = lockedKeyEngine(savedPassphrase: FakeEngine.lockedPassphrase)..configured();
    await tester.pumpWidget(appWith(
      engine,
      fileSaver: ({required String suggestedName, required String text}) async => null,
    ));
    await tester.pumpAndSettle();
    for (final item in ['Show public key as QR code', 'Install on a host…', 'Export private key…']) {
      await openKeyMenu(tester, item);
      if (item == 'Install on a host…') {
        await tapVisible(tester, find.byKey(const Key('install-host')));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('web-1 ·').last);
        await tester.pumpAndSettle();
      }
      if (item == 'Export private key…') {
        await tapVisible(tester, find.byKey(const Key('export-relock')));
        await tester.pumpAndSettle();
      }
      await tapVisible(tester, find.text(item == 'Show public key as QR code' ? 'Close' : 'Cancel').last);
      await tester.pumpAndSettle();
    }
    // Through the hosts screen's sync line, which goes straight to Sync.
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Synced just now'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-summary')), findsOneWidget, reason: 'on the Sync screen');
    await tester.scrollUntilVisible(find.text('Show code'), 150, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show code'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('join-code-view')), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    // An overflow anywhere above would have failed the test.
  });
}
