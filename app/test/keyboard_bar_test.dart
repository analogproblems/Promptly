import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/features/terminal/keyboard_bar.dart';
import 'package:promptly/features/terminal/keyboard_bar_keys.dart';
import 'package:promptly/features/terminal/terminal_controller.dart';

import 'widget_test.dart';

List<int> esc(String s) => [0x1b, ...s.codeUnits];

/// The bar alone at the foot of a phone screen, on a fake engine.
Widget barApp(FakeEngine engine, TerminalController c) => ProviderScope(
  overrides: [engineProvider.overrideWithValue(engine)],
  child: MaterialApp(
    theme: buildPromptlyTheme(Brightness.dark),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: KeyboardBar(controller: c, onSnippets: () {}),
      ),
    ),
  ),
);

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 760);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A bar holding just these keys, so all of them are on screen.
Future<(FakeEngine, TerminalController)> pumpBar(WidgetTester tester, List<String> keys) async {
  phone(tester);
  final engine = FakeEngine()..settings[BarLayoutNotifier.settingKey] = '[${keys.map((k) => '"$k"').join(',')}]';
  final c = TerminalController(engine: engine, id: 1, label: 'test');
  await tester.pumpWidget(barApp(engine, c));
  await tester.pump();
  return (engine, c);
}

void main() {
  group('what the bar keys send', () {
    test('arrows follow the cursor-key mode when nothing is held', () {
      expect(barKeySequence('up'), esc('[A'));
      expect(barKeySequence('down'), esc('[B'));
      expect(barKeySequence('right'), esc('[C'));
      expect(barKeySequence('left'), esc('[D'));
      expect(barKeySequence('left', appCursor: true), esc('OD'));
      expect(barKeySequence('up', appCursor: true), esc('OA'));
    });

    test('Ctrl and Alt go into the arrow sequence, as xterm sends them', () {
      expect(barKeySequence('left', ctrl: true), esc('[1;5D'), reason: 'a word left in a shell');
      expect(barKeySequence('right', ctrl: true), esc('[1;5C'));
      expect(barKeySequence('up', alt: true), esc('[1;3A'));
      expect(barKeySequence('down', ctrl: true, alt: true), esc('[1;7B'));
      expect(
        barKeySequence('left', ctrl: true, appCursor: true),
        esc('[1;5D'),
        reason: 'modified arrows are always CSI',
      );
    });

    test('Home, End and the paging keys carry modifiers too', () {
      expect(barKeySequence('home'), esc('[H'));
      expect(barKeySequence('end'), esc('[F'));
      expect(barKeySequence('home', ctrl: true), esc('[1;5H'));
      expect(barKeySequence('end', alt: true), esc('[1;3F'));
      expect(barKeySequence('pgup'), esc('[5~'));
      expect(barKeySequence('pgdn'), esc('[6~'));
      expect(barKeySequence('pgup', ctrl: true), esc('[5;5~'));
      expect(barKeySequence('pgdn', ctrl: true, alt: true), esc('[6;7~'));
      expect(barKeySequence('del'), esc('[3~'));
      expect(barKeySequence('del', alt: true), esc('[3;3~'));
      expect(barKeySequence('ins'), esc('[2~'));
    });

    test('function keys', () {
      expect(barKeySequence('f1'), esc('OP'));
      expect(barKeySequence('f4'), esc('OS'));
      expect(barKeySequence('f1', ctrl: true), esc('[1;5P'));
      expect(barKeySequence('f5'), esc('[15~'));
      expect(barKeySequence('f12'), esc('[24~'));
      expect(barKeySequence('f10', alt: true), esc('[21;3~'));
    });

    test('Alt puts Escape before Esc and Tab', () {
      expect(barKeySequence('esc'), [0x1b]);
      expect(barKeySequence('esc', alt: true), [0x1b, 0x1b]);
      expect(barKeySequence('tab'), [0x09]);
      expect(barKeySequence('tab', alt: true), [0x1b, 0x09]);
      expect(barKeySequence('tab', ctrl: true), [0x09]);
    });

    test('every key on the list has a sequence or a character', () {
      for (final k in barKeys) {
        if (k.isModifier) continue;
        expect(k.char != null || barKeySequence(k.id).isNotEmpty, isTrue, reason: k.id);
      }
      expect(barKeys.map((k) => k.id).toSet(), hasLength(barKeys.length), reason: 'ids are unique');
    });
  });

  group('the chosen layout', () {
    List<String> read(String? stored) {
      final engine = FakeEngine();
      if (stored != null) engine.settings[BarLayoutNotifier.settingKey] = stored;
      final container = ProviderContainer(overrides: [engineProvider.overrideWithValue(engine)]);
      addTearDown(container.dispose);
      return container.read(barLayoutProvider);
    }

    test('is the usual keys until chosen', () {
      expect(read(null), defaultBarLayout);
      expect(read('not json'), defaultBarLayout);
      expect(read('{"esc": true}'), defaultBarLayout);
    });

    test('keeps known keys once each, in order', () {
      expect(read('["f1","esc","nonsense","esc","left"]'), ['f1', 'esc', 'left']);
      expect(read('[]'), isEmpty);
    });

    test('is stored when changed', () {
      final engine = FakeEngine();
      final container = ProviderContainer(overrides: [engineProvider.overrideWithValue(engine)]);
      addTearDown(container.dispose);
      final layout = container.read(barLayoutProvider.notifier);
      layout.remove('esc');
      layout.add('f1');
      layout.move(0, 2);
      expect(container.read(barLayoutProvider).take(3), ['ctrl', 'alt', 'tab']);
      expect(container.read(barLayoutProvider).last, 'f1');
      expect(engine.settings[BarLayoutNotifier.settingKey], startsWith('["ctrl","alt","tab",'));
      layout.reset();
      expect(container.read(barLayoutProvider), defaultBarLayout);
    });
  });

  testWidgets('the bar shows the chosen keys in the chosen order', (tester) async {
    await pumpBar(tester, ['f1', 'esc', 'left']);
    expect(find.byKey(const Key('kb-tab')), findsNothing);
    final xs = [
      for (final id in ['f1', 'esc', 'left']) tester.getTopLeft(find.byKey(Key('kb-$id'))).dx,
    ];
    expect(xs, orderedEquals([...xs]..sort()));
  });

  testWidgets('sticky Ctrl with an arrow sends Ctrl+arrow, then lets go', (tester) async {
    final (engine, c) = await pumpBar(tester, ['ctrl', 'alt', 'left', 'right', 'pgdn']);
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump();
    expect(c.stickyCtrl, isTrue);
    await tester.tap(find.byKey(const Key('kb-left')));
    await tester.pump();
    expect(engine.written.last, esc('[1;5D'));
    expect(c.stickyCtrl, isFalse, reason: 'one-shot');
    await tester.tap(find.byKey(const Key('kb-right')));
    expect(engine.written.last, esc('[C'));

    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('kb-alt')));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('kb-pgdn')));
    expect(engine.written.last, esc('[6;7~'), reason: 'both held');
  });

  testWidgets('a quick second tap locks Ctrl until it is tapped again', (tester) async {
    final (engine, c) = await pumpBar(tester, ['ctrl', 'alt', 'left']);
    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(find.byKey(const Key('kb-ctrl')));
    expect((node.label, node.value), ('Control', 'off'));
    expect(node.hint, contains('lock'), reason: 'says how to lock it');

    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump();
    expect(c.lockedCtrl, isTrue);
    expect(find.byKey(const Key('kb-ctrl-locked')), findsOneWidget, reason: 'a padlock, not just a colour');
    expect(tester.getSemantics(find.byKey(const Key('kb-ctrl'))).value, 'locked');

    // Stays down across keys and typing.
    await tester.tap(find.byKey(const Key('kb-left')));
    expect(engine.written.last, esc('[1;5D'));
    expect(c.encodeTyped('c'), [3]);
    expect(c.encodeTyped('d'), [4]);
    expect(c.stickyCtrl, isTrue);

    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump();
    expect(c.stickyCtrl || c.lockedCtrl, isFalse);
    expect(find.byKey(const Key('kb-ctrl-locked')), findsNothing);
    expect(c.encodeTyped('c'), 'c'.codeUnits);
    semantics.dispose();
  });

  testWidgets('a slow second tap lets go instead of locking, and a long press locks', (tester) async {
    final (_, c) = await pumpBar(tester, ['ctrl', 'alt']);
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump();
    expect(c.stickyCtrl, isFalse);
    expect(c.lockedCtrl, isFalse);

    await tester.longPress(find.byKey(const Key('kb-alt')));
    await tester.pump();
    expect(c.lockedAlt, isTrue);
    expect(find.byKey(const Key('kb-alt-locked')), findsOneWidget);
  });

  testWidgets('holding an arrow key and sliding sends arrows the way the finger goes', (tester) async {
    final (engine, c) = await pumpBar(tester, ['ctrl', 'left', 'down', 'up', 'right']);
    final bar = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final at = tester.getCenter(find.byKey(const Key('kb-left')));

    Future<void> slide(Offset step, int steps) async {
      final gesture = await tester.startGesture(at);
      await tester.pump(KeyboardBar.slideHold + const Duration(milliseconds: 50));
      for (var i = 0; i < steps; i++) {
        await gesture.moveBy(step);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
    }

    await slide(const Offset(12, 0), 10);
    expect(engine.written, hasLength(120 ~/ KeyboardBar.slideStep), reason: '120 px of travel');
    expect(engine.written.every((w) => _eq(w, esc('[C'))), isTrue, reason: 'right, though it started on left');
    expect(bar.position.pixels, 0, reason: 'the slide did not scroll the bar');

    engine.written.clear();
    await slide(const Offset(0, -12), 6);
    expect(engine.written, isNotEmpty);
    expect(engine.written.every((w) => _eq(w, esc('[A'))), isTrue);

    // Ctrl applies to the whole slide, and lets go after it.
    engine.written.clear();
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump(const Duration(seconds: 1));
    await slide(const Offset(-12, 0), 4);
    expect(engine.written, hasLength(48 ~/ KeyboardBar.slideStep));
    expect(engine.written.every((w) => _eq(w, esc('[1;5D'))), isTrue);
    expect(c.stickyCtrl, isFalse);
  });

  testWidgets('a quick swipe that starts on an arrow key still scrolls the bar', (tester) async {
    // An arrow key first, and enough keys after it that the bar scrolls.
    final (engine, _) = await pumpBar(tester, ['left', ...defaultBarLayout.where((k) => k != 'left')]);
    final bar = tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.drag(find.byKey(const Key('kb-left')), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(bar.position.pixels, greaterThan(0));
    expect(engine.written, isEmpty);
  });

  testWidgets('the bar fits a narrow phone at double text size', (tester) async {
    phone(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final engine = FakeEngine();
    final c = TerminalController(engine: engine, id: 1, label: 'test');
    await tester.pumpWidget(barApp(engine, c));
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump();
    expect(find.byKey(const Key('kb-ctrl-locked')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings chooses, orders and restores the keys on the bar', (tester) async {
    phone(tester);
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('keyboard-bar-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard bar'), findsOneWidget);
    List<String> stored() =>
        (engine.settings[BarLayoutNotifier.settingKey] ?? '').replaceAll(RegExp(r'[\[\]"]'), '').split(',');

    await tester.tap(find.byKey(const Key('kb-layout-remove-esc')));
    await tester.pumpAndSettle();
    expect(stored().first, 'tab');
    expect(find.byKey(const Key('kb-layout-esc')), findsNothing);

    // Tab moves down past Ctrl by its handle.
    final handle = tester.getCenter(find.byKey(const Key('kb-layout-handle-tab')));
    final rowHeight = tester.getSize(find.byKey(const ValueKey('kb-layout-tab'))).height;
    final drag = await tester.startGesture(handle);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 6; i++) {
      await drag.moveBy(Offset(0, rowHeight * 1.5 / 6));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await drag.up();
    await tester.pumpAndSettle();
    expect(stored().take(2), ['ctrl', 'tab']);

    await scrollTap(tester, find.byKey(const Key('kb-layout-add-f1')));
    await tester.pumpAndSettle();
    expect(stored().last, 'f1');
    expect(find.byKey(const Key('kb-layout-add-f1')), findsNothing, reason: 'it is on the bar now');

    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kb-layout-reset')));
    await tester.pumpAndSettle();
    expect(stored(), defaultBarLayout);
  });

  testWidgets('the keyboard bar page fits a narrow phone at double text size', (tester) async {
    phone(tester);
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('keyboard-bar-settings')));
    await tester.pumpAndSettle();
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final page = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.byKey(const Key('kb-layout-remove-esc')), 200, scrollable: page);
    await tester.scrollUntilVisible(find.byKey(const Key('kb-layout-add-f12')), 400, scrollable: page);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

bool _eq(List<int> a, List<int> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
