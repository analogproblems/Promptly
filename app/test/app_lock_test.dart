import 'dart:async';

import 'package:flutter/material.dart' hide LockState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/features/lock/app_lock.dart';
import 'package:promptly/features/lock/lock_gate.dart';
import 'package:promptly/features/sessions/connect_flow.dart';

import 'widget_test.dart' show FakeEngine, appWith, hostJson, scrollTap;

class FakeAuthenticator implements Authenticator {
  FakeAuthenticator({this.system = true, this.answer = true});

  bool system;
  bool answer;
  final List<String> asked = [];

  /// When set, the system check is only known once this completes.
  Completer<bool>? probe;

  @override
  Future<bool> systemAvailable() async => probe != null ? probe!.future : system;

  @override
  Future<bool> systemCheck(String reason) async {
    asked.add(reason);
    return answer;
  }

  @override
  Future<String> hashPasscode(String passcode) async => 'hash:$passcode';

  @override
  Future<bool> verifyPasscode(String passcode, String hash) async => hash == 'hash:$passcode';
}

SshConnectRequest _request({String? key, String? jumpKey}) => SshConnectRequest(
      user: 'me',
      host: 'h',
      port: 22,
      auth: key == null ? SshAuthKind.password : SshAuthKind.key,
      password: null,
      privateKey: key,
      passphrase: null,
      cols: 80,
      rows: 24,
      theme: 'promptly-dark',
      label: null,
      keepaliveSeconds: 30,
      reattachSessionId: null,
      jumps: [
        if (jumpKey != null)
          SshHop(user: 'me', host: 'bastion', port: 22, auth: SshAuthKind.key, privateKey: jumpKey),
      ],
      persistent: false,
      startupCommand: null,
      env: const [],
      agentForward: false,
      forwards: const [],
    );

void main() {
  testWidgets('with the app lock on, Promptly opens locked and unlocks after the check', (tester) async {
    final engine = FakeEngine()..settings['app_lock'] = 'true';
    final auth = FakeAuthenticator(answer: false);
    await tester.pumpWidget(appWith(engine, authenticator: auth));
    await tester.pumpAndSettle();
    expect(find.text('Promptly is locked'), findsOneWidget);
    expect(auth.asked, ['Unlock Promptly'], reason: 'asked straight away');

    auth.answer = true;
    await tester.tap(find.byKey(const Key('unlock-app')));
    await tester.pumpAndSettle();
    expect(find.text('Promptly is locked'), findsNothing);
  });

  testWidgets('without a system check, the app passcode unlocks', (tester) async {
    final engine = FakeEngine()
      ..settings['app_lock'] = 'true'
      ..settings['app_passcode'] = '"hash:2468"';
    await tester.pumpWidget(appWith(engine, authenticator: FakeAuthenticator(system: false)));
    await tester.pumpAndSettle();
    expect(find.text('Promptly is locked'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('app-passcode')), '1111');
    await tester.tap(find.byKey(const Key('app-passcode-ok')));
    await tester.pumpAndSettle();
    expect(find.text('That is not the passcode.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('app-passcode')), '2468');
    await tester.tap(find.byKey(const Key('app-passcode-ok')));
    await tester.pumpAndSettle();
    expect(find.text('Promptly is locked'), findsNothing);
  });

  test('a connection with a key waits for the unlock, and a refusal stops it', () async {
    final engine = FakeEngine();
    final refused = ConnectFlow(engine: engine, request: _request(key: 'KEY'), unlock: () async => false);
    await refused.start();
    expect(engine.requests, isEmpty, reason: 'the key never reached the engine');
    expect(refused.error, contains('stays locked'));

    final allowed = ConnectFlow(engine: engine, request: _request(key: 'KEY'), unlock: () async => true);
    await allowed.start();
    expect(engine.requests, hasLength(1));

    var asked = false;
    final noKey = ConnectFlow(
      engine: engine,
      request: _request(),
      unlock: () async => asked = true,
    );
    await noKey.start();
    expect(asked, isFalse, reason: 'a password login is not gated');

    final jumpOnly = ConnectFlow(
      engine: engine,
      request: _request(jumpKey: 'JUMPKEY'),
      unlock: () async => false,
    );
    await jumpOnly.start();
    expect(engine.requests, hasLength(2), reason: "a jump host's key is gated too");
    expect(jumpOnly.error, contains('stays locked'));
  });

  const hostRow = Key('host-row-h1');

  testWidgets('nothing of the app shows while Promptly is still finding out how to check', (tester) async {
    final engine = FakeEngine()..settings['app_lock'] = 'true';
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    final auth = FakeAuthenticator()..probe = Completer<bool>();
    await tester.pumpWidget(appWith(engine, authenticator: auth));
    await tester.pump();
    await tester.pump();
    expect(find.text('Promptly is locked'), findsOneWidget);
    expect(find.byKey(hostRow), findsNothing);

    auth.probe!.complete(true);
    await tester.pumpAndSettle();
    expect(auth.asked, ['Unlock Promptly']);
    expect(find.byKey(hostRow), findsOneWidget);
  });

  testWidgets('an app lock with nothing left to check with stays shut', (tester) async {
    // The lock was on, then the device's screen lock went (or the check
    // broke): Promptly stays locked and says what to do.
    final engine = FakeEngine()..settings['app_lock'] = 'true';
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    await tester.pumpWidget(appWith(engine, authenticator: FakeAuthenticator(system: false)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no-check')), findsOneWidget);
    await tester.tap(find.byKey(const Key('unlock-app')));
    await tester.pumpAndSettle();
    expect(find.text('Promptly is locked'), findsOneWidget);
    expect(find.byKey(hostRow), findsNothing);
  });

  testWidgets('a locked app gets no key presses, and gets the keyboard back on unlocking', (tester) async {
    final engine = FakeEngine()..settings['app_lock'] = 'true';
    final auth = FakeAuthenticator();
    final typed = <LogicalKeyboardKey>[];
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [engineProvider.overrideWithValue(engine), authenticatorProvider.overrideWithValue(auth)],
        child: MaterialApp(
          theme: buildPromptlyTheme(Brightness.dark),
          home: LockGate(
            child: Scaffold(
              body: Column(
                children: [
                  Focus(
                    focusNode: node,
                    onKeyEvent: (_, e) {
                      if (e is KeyDownEvent) typed.add(e.logicalKey);
                      return KeyEventResult.handled;
                    },
                    child: const SizedBox(width: 10, height: 10),
                  ),
                  const TextField(key: Key('other-field')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(typed, [LogicalKeyboardKey.keyA], reason: 'unlocked, keys arrive');

    // Lock while it has the keyboard, and refuse the check.
    auth.answer = false;
    ProviderScope.containerOf(tester.element(find.byType(LockGate))).read(appLockProvider.notifier).lockNow();
    await tester.pumpAndSettle();
    expect(find.text('Promptly is locked'), findsOneWidget);
    expect(node.hasFocus, isFalse);
    for (final key in [
      LogicalKeyboardKey.keyB,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    expect(typed, [LogicalKeyboardKey.keyA], reason: 'nothing reaches the locked app');
    expect(node.hasFocus, isFalse);
    expect(
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(),
      isNull,
      reason: 'moving between fields does not reach into the locked app',
    );
    expect(find.text('Promptly is locked'), findsOneWidget, reason: 'Enter on Unlock asked again and was refused');

    auth.answer = true;
    await tester.tap(find.byKey(const Key('unlock-app')));
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue, reason: 'the keyboard goes back where it was');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(typed, [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD]);
  });

  testWidgets('Test connection asks before using a key, and stops when refused', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 9;
    engine.records['identities'] = {
      'k1': '{"id":"k1","label":"laptop","key_type":"ed25519","public_key":"ssh-ed25519 AAAA","private_key_secret_id":"s1"}',
    };
    engine.secrets['s1'] = '-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----';
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1', auth: '{"kind":"identity","identity_id":"k1"}')};
    final auth = FakeAuthenticator(answer: false);
    await tester.pumpWidget(appWith(engine, authenticator: auth));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Host actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('host-test')));
    await tester.pumpAndSettle();
    expect(auth.asked, ['Unlock your SSH key']);
    expect(engine.requests, isEmpty, reason: 'the key never reached the engine');
    expect(find.textContaining('stays locked'), findsOneWidget);
  });

  testWidgets('turning the locks down asks first, and a refusal changes nothing', (tester) async {
    final engine = FakeEngine();
    final auth = FakeAuthenticator(answer: false);
    await tester.pumpWidget(appWith(engine, authenticator: auth));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();

    await scrollTap(tester, find.byKey(const Key('key-unlock')));
    await tester.pumpAndSettle();
    expect(auth.asked, ['Turn off unlocking SSH keys']);
    expect(engine.settings['key_unlock'], isNull, reason: 'refused, so not saved');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('key-unlock'))).value, isTrue);
    final container = ProviderScope.containerOf(tester.element(find.byType(LockGate)));
    expect(
      await container.read(appLockProvider.notifier).unlockKeys(),
      isFalse,
      reason: 'keys still ask, and the refusing check keeps them locked',
    );

    auth.answer = true;
    await scrollTap(tester, find.byKey(const Key('key-unlock')));
    await tester.pumpAndSettle();
    expect(engine.settings['key_unlock'], 'false');
  });
}
