import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/file_picker.dart';
import 'package:promptly/core/licences.dart';
import 'package:promptly/core/platform.dart';
import 'package:promptly/features/sessions/sessions_screen.dart';
import 'package:promptly/features/terminal/terminal_view.dart';

import 'widget_test.dart';

/// A 360-wide phone with the text twice its usual size. Reset after the test.
void smallPhoneLargeText(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = 2.0;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// A host with a forward, so every tool in the session bar shows.
String forwardingHost(String id, String label, {String? group}) => hostJson(id, label, group: group).replaceFirst(
  '"port_forwards":[]',
  '"port_forwards":[{"kind":"local","bind_host":"","bind_port":8080,"target_host":"db","target_port":5432,"auto":true}]',
);

/// Let a snack bar go: on the Hosts tab it sits over the add button.
Future<void> waitOutSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the hosts list fits a 360-wide phone at double text size', (tester) async {
    smallPhoneLargeText(tester);
    final engine = FakeEngine()..settings['reachability_check'] = 'true';
    engine.records['groups'] = {
      'g1': '{"id":"g1","label":"Production servers in Europe","parent_id":null,"color":null,"defaults":{}}',
    };
    engine.records['hosts'] = {
      'h1': hostJson(
        'h1',
        'web-frontend-europe-1',
        group: 'g1',
        favourite: true,
        lastConnected: '2026-10-16T08:00:00Z',
      ),
      'h2': hostJson('h2', 'db', group: 'g1', auth: '{"kind":"password","password_secret_id":"p"}'),
      'h3': hostJson('h3', 'nas', lastConnected: DateTime.now().toUtc().toIso8601String()),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-row-h1')), findsOneWidget);
    // Picking hosts swaps the header for the selection bar.
    await tester.longPress(find.byKey(const Key('host-row-h2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hosts-select-count')), findsOneWidget);
    await tester.tap(find.byKey(const Key('hosts-select-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hosts-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-import-csv')), findsOneWidget);
    // An overflow anywhere above would have failed the test.
  });

  testWidgets('a session fits a 360-wide phone at double text size', (tester) async {
    smallPhoneLargeText(tester);
    touchPlatformOverride = true;
    addTearDown(() => touchPlatformOverride = null);
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'a1': forwardingHost('a1', 'application-server-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-a1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-search')), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-field')), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-forwards')), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-snippets')));
    await tester.pumpAndSettle();
    // An overflow anywhere above would have failed the test.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an ended shell fits a 360-wide phone at double text size', (tester) async {
    smallPhoneLargeText(tester);
    final engine = FakeEngine()
      ..connectedSessionId = 1
      ..dropAfterFrame = true;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(RegExp('^(Open a l|L)ocal shell')).first);
    await tester.pumpAndSettle();
    expect(find.text('New shell'), findsOneWidget);
    // An overflow anywhere above would have failed the test.
  });

  group('hosts list', () {
    FakeEngine hostsEngine() {
      final engine = FakeEngine()..connectedSessionId = 7;
      engine.records['groups'] = {'g1': '{"id":"g1","label":"Production","parent_id":null,"color":null,"defaults":{}}'};
      engine.records['hosts'] = {
        'h1': hostJson('h1', 'web-1', group: 'g1'),
        'h2': hostJson('h2', 'web-2', group: 'g1'),
        'h3': hostJson('h3', 'nas'),
      };
      return engine;
    }

    String? groupOf(FakeEngine engine, String id) {
      final json = engine.records['hosts']![id]!;
      final m = RegExp(r'"group_id":"([^"]*)"').firstMatch(json);
      return m?.group(1);
    }

    testWidgets('on a phone, swiping a host right connects and left opens it to edit', (tester) async {
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      final engine = hostsEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const Key('host-row-h3')), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(engine.requests.single.host, 'nas.example');
      expect(find.byKey(const Key('session-search')), findsOneWidget, reason: 'the session is showing');

      await tester.tap(find.text('Hosts').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-row-h3')), findsOneWidget, reason: 'the row springs back');
      await tester.drag(find.byKey(const Key('host-row-h3')), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Edit host'), findsOneWidget);
      expect(engine.requests, hasLength(1), reason: 'editing connects nowhere');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('swiping is for phones; with a mouse a drag does nothing', (tester) async {
      final engine = hostsEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const Key('host-row-h3')), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(engine.requests, isEmpty);
      expect(find.byType(Dismissible), findsNothing);
    });

    testWidgets('a long press picks hosts, which move to a group together', (tester) async {
      final engine = hostsEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const Key('host-row-h1')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byKey(const Key('hosts-add')), findsNothing, reason: 'no add button while picking');
      // While picking, a tap picks another instead of connecting.
      await tester.tap(find.byKey(const Key('host-row-h3')));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      expect(engine.requests, isEmpty);
      await tester.tap(find.byKey(const Key('host-row-h1')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('host-row-h2')));
      await tester.pumpAndSettle();

      // web-2 and nas into Production: nas joins it, web-2 was there already.
      await tester.tap(find.byKey(const Key('hosts-move')));
      await tester.pumpAndSettle();
      expect(find.text('Move 2 hosts to'), findsOneWidget);
      await tester.tap(find.byKey(const Key('move-to-g1')));
      await tester.pumpAndSettle();
      expect(groupOf(engine, 'h3'), 'g1');
      expect(groupOf(engine, 'h2'), 'g1');
      expect(groupOf(engine, 'h1'), 'g1');
      expect(find.text('Moved 2 hosts to Production.'), findsOneWidget);
      expect(find.text('Hosts'), findsWidgets, reason: 'the header is back');

      // Into a new group, made on the way.
      await tester.longPress(find.byKey(const Key('host-row-h3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('move-to-new')));
      await tester.pumpAndSettle();
      expect(find.text('New group'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('group-label')), 'Homelab');
      await tester.tap(find.byKey(const Key('group-save')));
      await tester.pumpAndSettle();
      final homelab = engine.records['groups']!.entries.firstWhere((e) => e.value.contains('Homelab')).key;
      expect(groupOf(engine, 'h3'), homelab);
      expect(find.text('HOMELAB'), findsOneWidget);

      // And out of any group.
      await tester.longPress(find.byKey(const Key('host-row-h3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('move-to-none')));
      await tester.pumpAndSettle();
      expect(groupOf(engine, 'h3'), isNull);
    });

    testWidgets('picked hosts are deleted together after one question, and Select is in the menu', (tester) async {
      final engine = hostsEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byKey(const Key('host-row-h1')), matching: find.byTooltip('Host actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-check-h1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('host-row-h3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 hosts?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(engine.records['hosts'], hasLength(3), reason: 'nothing goes without a yes');
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hosts-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-delete-confirm')));
      await tester.pumpAndSettle();
      expect(engine.records['hosts']!.keys, ['h2']);
      expect(find.byKey(const Key('hosts-select-count')), findsNothing);

      // Stop picking without doing anything.
      await tester.longPress(find.byKey(const Key('host-row-h2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-select-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hosts-select-count')), findsNothing);
      await tester.tap(find.byKey(const Key('host-row-h2')));
      await tester.pumpAndSettle();
      expect(engine.requests.single.host, 'web-2.example', reason: 'a tap connects again');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a group folds shut and stays that way, but a search still finds its hosts', (tester) async {
      final engine = hostsEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-row-h1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-toggle-g1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-row-h1')), findsNothing);
      expect(find.byKey(const Key('host-row-h2')), findsNothing);
      expect(find.byKey(const Key('host-row-h3')), findsOneWidget, reason: 'other groups stay open');
      expect(find.text('PRODUCTION'), findsOneWidget, reason: 'the header stays, to open it again');
      expect(engine.settings['hosts_collapsed_groups'], '["g1"]');

      // Remembered the next time the app opens.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-row-h1')), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'web-1');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-row-h1')), findsOneWidget, reason: 'a match is never hidden');
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('group-toggle-g1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-row-h1')), findsOneWidget);
      expect(engine.settings['hosts_collapsed_groups'], '[]');
    });

    testWidgets('the add button offers a host, a group or an import', (tester) async {
      const csv = 'Label,Hostname/IP,Username\nweb-9,10.0.0.9,deploy\n';
      final engine = hostsEngine();
      await tester.pumpWidget(
        appWith(
          engine,
          pickedFile: const PickedTextFile(name: 'hosts.csv', text: csv),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add a host, group or import'), findsOneWidget);

      await tester.tap(find.byKey(const Key('hosts-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-host')), findsOneWidget);
      expect(find.byKey(const Key('add-group')), findsOneWidget);
      expect(find.byKey(const Key('add-import-csv')), findsOneWidget);
      expect(find.byKey(const Key('add-import-ssh-config')), findsOneWidget, reason: 'on a computer');
      await tester.tap(find.byKey(const Key('add-group')));
      await tester.pumpAndSettle();
      expect(find.text('New group'), findsOneWidget);
      expect(find.byKey(const Key('group-delete')), findsNothing, reason: 'nothing to delete yet');
      await tester.tap(find.byKey(const Key('group-save')));
      await tester.pumpAndSettle();
      expect(find.text('Give the group a name.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('group-label')), 'Clients');
      await tester.enterText(find.byKey(const Key('group-user')), 'admin');
      await tester.tap(find.byKey(const Key('group-save')));
      await tester.pumpAndSettle();
      final clients = engine.records['groups']!.values.firstWhere((j) => j.contains('Clients'));
      expect(clients, contains('"username":"admin"'));

      await tester.tap(find.byKey(const Key('hosts-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-import-csv')));
      await tester.pumpAndSettle();
      expect(find.text('Import from hosts.csv'), findsOneWidget);
      await tester.tap(find.byKey(const Key('csv-import-go')));
      await tester.pumpAndSettle();
      expect(find.text('web-9'), findsOneWidget);
      await waitOutSnackBar(tester);

      await tester.tap(find.byKey(const Key('hosts-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-host')));
      await tester.pumpAndSettle();
      expect(find.text('New host'), findsOneWidget);
    });

    testWidgets('picking, moving and adding fit a 360-wide phone at double text size', (tester) async {
      smallPhoneLargeText(tester);
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      final engine = hostsEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const Key('host-row-h1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('move-to-none')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const Key('host-row-h3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-select-cancel')));
      await tester.pumpAndSettle();
      await waitOutSnackBar(tester);
      // Half a swipe, to show what it will do.
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('host-row-h3'))));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(find.text('Connect'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hosts-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('group-save')));
      await tester.pumpAndSettle();
      expect(find.text('Give the group a name.'), findsOneWidget);
      // An overflow anywhere above would have failed the test.
    });
  });

  group('sessions tab', () {
    Future<void> openShell(WidgetTester tester) async {
      await tester.tap(find.text('Sessions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(RegExp('^(Open a l|L)ocal shell')).first);
      await tester.pumpAndSettle();
    }

    Finder badge(String text) =>
        find.descendant(of: find.byKey(const Key('sessions-count')), matching: find.text(text));

    testWidgets('the tab counts open sessions, and a card swiped away is closed', (tester) async {
      final engine = FakeEngine()..connectedSessionId = 1;
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessions-count')), findsWidgets);
      expect(find.descendant(of: find.byKey(const Key('sessions-count')), matching: find.byType(Text)), findsNothing);
      await openShell(tester);
      expect(badge('1'), findsWidgets);
      await tester.tap(find.byTooltip('Back to sessions'));
      await tester.pumpAndSettle();
      await openShell(tester);
      await tester.tap(find.byTooltip('Back to sessions'));
      await tester.pumpAndSettle();
      expect(badge('2'), findsWidgets);
      expect(find.byType(SessionCard), findsNWidgets(2));

      await tester.drag(find.byType(SessionCard).first, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SessionCard), findsOneWidget);
      expect(badge('1'), findsWidgets);
      await tester.drag(find.byType(SessionCard).first, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SessionCard), findsNothing);
      expect(find.text('No live sessions'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('sessions-count')), matching: find.byType(Text)), findsNothing);
    });

    testWidgets('the count is read out with the tab', (tester) async {
      final handle = tester.ensureSemantics();
      final engine = FakeEngine()..connectedSessionId = 1;
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await openShell(tester);
      expect(find.bySemanticsLabel(RegExp('1 open')), findsWidgets);
      handle.dispose();
    });
  });

  group('sync passphrase', () {
    /// From the sync status in the Hosts header to the passphrase step.
    Future<void> toPassphrase(WidgetTester tester) async {
      await tester.tap(find.text('Vault not set up'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('sync-continue')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sync-path')), '/tmp/vault');
      await tapVisible(tester, find.byKey(const Key('sync-folder-continue')));
      await tester.pumpAndSettle();
    }

    String advice(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('passphrase-advice'))).textSpan!.toPlainText();

    testWidgets('a meter says how strong it is, with no rules, and only a very weak one is refused', (tester) async {
      final engine = FakeEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await toPassphrase(tester);
      expect(find.byKey(const Key('passphrase-meter')), findsNothing, reason: 'nothing until something is typed');
      expect(find.textContaining('at least'), findsNothing, reason: 'no length rule is shown');

      await tester.enterText(find.byKey(const Key('sync-passphrase')), 'password');
      await tester.pump();
      expect(advice(tester), startsWith('Too easy to guess. This is one of the passwords people use most'));
      await tester.enterText(find.byKey(const Key('sync-passphrase')), 'two words');
      await tester.pump();
      expect(advice(tester), startsWith('Weak.'));
      await tester.enterText(find.byKey(const Key('sync-passphrase')), 'correct horse battery');
      await tester.pump();
      expect(advice(tester), startsWith('Strong.'));

      // Refused in words, without calling the engine to make anything.
      await tester.enterText(find.byKey(const Key('sync-passphrase')), 'password');
      await tester.enterText(find.byKey(const Key('sync-passphrase-confirm')), 'password');
      await tapVisible(tester, find.byKey(const Key('sync-create')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('sync-error'))).data,
        'This is one of the passwords people use most.',
      );
      expect(engine.syncCalls, isEmpty);

      // A weak one is the person's choice.
      await tester.enterText(find.byKey(const Key('sync-passphrase')), 'two words');
      await tester.enterText(find.byKey(const Key('sync-passphrase-confirm')), 'two words');
      await tapVisible(tester, find.byKey(const Key('sync-create')));
      await tester.pumpAndSettle();
      expect(engine.syncCalls, ['create /tmp/vault test-box (Linux)']);
    });

    testWidgets('the meter is read out as one sentence', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app(FakeEngine()));
      await tester.pumpAndSettle();
      await toPassphrase(tester);
      await tester.enterText(find.byKey(const Key('sync-passphrase')), 'correct horse battery');
      await tester.pump();
      expect(find.bySemanticsLabel('Passphrase strength: Strong. Advice for level 3.'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('re-keying shows the meter too', (tester) async {
      final engine = FakeEngine()..configured();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      await scrollTap(tester, find.text('Open'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byTooltip('Remove device'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync-remove-rekey')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sync-rekey-passphrase')), 'short');
      await tester.pump();
      expect(advice(tester), startsWith('Too easy to guess.'));
    });

    testWidgets('the passphrase step fits a 360-wide phone at double text size', (tester) async {
      smallPhoneLargeText(tester);
      await tester.pumpWidget(app(FakeEngine()));
      await tester.pumpAndSettle();
      await toPassphrase(tester);
      await tester.enterText(find.byKey(const Key('sync-passphrase')), 'password');
      await tester.pump();
      await tapVisible(tester, find.byKey(const Key('sync-create')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-error')), findsOneWidget);
      // An overflow anywhere above would have failed the test.
    });
  });

  group('hardware keyboard settings', () {
    testWidgets('Caps Lock as Escape is a switch; Cmd as Ctrl shows on iPad and Mac only', (tester) async {
      final engine = FakeEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      await scrollTap(tester, find.byKey(const Key('caps-lock-escape')));
      await tester.pumpAndSettle();
      expect(engine.settings['caps_lock_escape'], 'true');
      expect(find.byKey(const Key('cmd-as-ctrl')), findsNothing, reason: 'an Android phone has no Cmd key');

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      await scrollTap(tester, find.byKey(const Key('cmd-as-ctrl')));
      await tester.pumpAndSettle();
      expect(engine.settings['cmd_as_ctrl'], 'true');
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the settings reach the terminal', (tester) async {
      final engine = FakeEngine()
        ..connectedSessionId = 1
        ..settings['caps_lock_escape'] = 'true'
        ..settings['cmd_as_ctrl'] = 'true';
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sessions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(RegExp('^(Open a l|L)ocal shell')).first);
      await tester.pumpAndSettle();
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.keys.capsLockAsEscape, isTrue);
      expect(view.keys.cmdAsCtrl, isFalse, reason: 'not offered on this platform, so not applied');
      engine.written.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
      await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
      expect(engine.written.first, [0x1b]);
    });

    testWidgets('the section fits a 360-wide phone at double text size', (tester) async {
      smallPhoneLargeText(tester);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(app(FakeEngine()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('cmd-as-ctrl')));
      // An overflow anywhere above would have failed the test.
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('Mac menu bar', () {
    /// Every item in the menus the app handed the system, depth first.
    Iterable<Map<Object?, Object?>> items(Object? node) sync* {
      if (node is Map) {
        if (node.containsKey('label')) yield node;
        for (final v in node.values) {
          yield* items(v);
        }
      } else if (node is List) {
        for (final v in node) {
          yield* items(v);
        }
      }
    }

    testWidgets('a Mac gets the system menu bar, not one drawn in the window', (tester) async {
      desktopWindow(tester);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      Object? menus;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, (call) async {
        if (call.method == 'Menu.setMenus') menus = call.arguments;
        return null;
      });
      await tester.pumpWidget(app(FakeEngine()));
      await tester.pumpAndSettle();
      expect(find.byType(MenuBar), findsNothing);
      final labels = [for (final i in items(menus)) i['label']];
      expect(labels, containsAll(['Promptly', 'File', 'Edit', 'View', 'Session', 'Window', 'Help']));
      expect(labels, containsAll(['About Promptly', 'Settings…', 'Quit Promptly', 'New tab', 'Split right']));
      final quit = items(menus).firstWhere((i) => i['label'] == 'Quit Promptly');
      expect(quit['shortcutTrigger'], isNotNull, reason: 'Cmd+Q quits');

      // Choosing an item does what it says.
      final settings = items(menus).firstWhere((i) => i['label'] == 'Settings…');
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/menu',
        SystemChannels.menu.codec.encodeMethodCall(MethodCall('Menu.selectedCallback', settings['id'])),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('terminal-theme')), findsOneWidget, reason: 'Settings is showing');

      await tester.pumpWidget(const SizedBox());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, null);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows and Linux keep the menu bar in the window', (tester) async {
      desktopWindow(tester);
      await tester.pumpWidget(app(FakeEngine()));
      await tester.pumpAndSettle();
      expect(find.byType(MenuBar), findsOneWidget);
      expect(find.byType(PlatformMenuBar), findsNothing);
    });
  });

  testWidgets('the licences include the engine\'s OpenSSL and SQLCipher', (tester) async {
    registerLicences();
    await tester.pumpWidget(app(FakeEngine()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('settings-about')));
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('about-licences')));
    await tester.pumpAndSettle();
    expect(find.text('OpenSSL'), findsOneWidget);
    expect(find.text('SQLCipher'), findsOneWidget);
    expect(find.text('JetBrains Mono'), findsOneWidget);
    await tester.tap(find.text('SQLCipher'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Zetetic LLC'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenSSL'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Apache License'), findsWidgets);
  });
}
