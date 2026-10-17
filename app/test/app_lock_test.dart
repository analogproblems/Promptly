import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/features/lock/app_lock.dart';
import 'package:promptly/features/sessions/connect_flow.dart';

import 'widget_test.dart' show FakeEngine, appWith;

class FakeAuthenticator implements Authenticator {
  FakeAuthenticator({this.system = true, this.answer = true});

  bool system;
  bool answer;
  final List<String> asked = [];

  @override
  Future<bool> systemAvailable() async => system;

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

SshConnectRequest _request({String? key}) => SshConnectRequest(
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
      jumps: const [],
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
  });
}
