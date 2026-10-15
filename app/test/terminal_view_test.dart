import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/features/terminal/terminal_controller.dart';
import 'package:promptly/features/terminal/terminal_view.dart';

/// Records what the view asks of the engine.
class RecordingEngine implements Engine {
  final List<String> calls = [];

  /// What the engine reports as selected text.
  String? selection;

  @override
  String version() => 'test';
  @override
  String ping(String name) => name;
  @override
  EndpointParse parseEndpoint(String input) => const EndpointError('n/a');
  @override
  int terminalOpenLocal({required int cols, required int rows, required String theme}) => 1;
  @override
  Stream<TerminalEvent> terminalEvents(int id) {
    calls.add('events');
    return const Stream.empty();
  }

  @override
  void terminalWrite(int id, List<int> data) => calls.add('write ${data.length}');
  @override
  void terminalPaste(int id, String text) => calls.add('paste');
  @override
  void terminalResize(int id, int cols, int rows) => calls.add('resize $cols x $rows');
  @override
  void terminalScroll(int id, int delta) => calls.add('scroll $delta');
  @override
  void terminalScrollToBottom(int id) => calls.add('bottom');
  @override
  void terminalSetTheme(int id, String theme) => calls.add('theme $theme');
  @override
  void terminalRefresh(int id) => calls.add('refresh');
  @override
  void terminalSelectBegin(int id, int col, int line, bool sideRight, TerminalSelectKind kind) =>
      calls.add('select ${kind.name} $col,$line');
  @override
  void terminalSelectUpdate(int id, int col, int line, bool sideRight) => calls.add('extend $col,$line');
  @override
  void terminalSelectClear(int id) => calls.add('clear');
  @override
  String? terminalSelectionText(int id) => selection;
  @override
  void terminalClose(int id) => calls.add('close');
  @override
  void setDataDir(String path) {}
  @override
  List<ThemeInfo> themesList() => const [];
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
  List<StoreRecord> recordsList(String collection) => const [];
  @override
  StoreRecord? recordGet(String collection, String id) => null;
  @override
  void recordPut(String collection, String id, String json) {}
  @override
  bool recordDelete(String collection, String id) => false;
  @override
  String? settingGet(String key) => null;
  @override
  void settingSet(String key, String json) {}
  @override
  void secretPut(String id, String value) {}
  @override
  String? secretGet(String id) => null;
  @override
  void secretDelete(String id) {}
  @override
  GeneratedKey keyGenerate(SshKeyKind kind, String comment) => throw UnimplementedError();
  @override
  KeyInfo keyInspect(String privateKey, String? passphrase) => throw UnimplementedError();
  @override
  String keyFingerprint(String publicKey) => 'SHA256:test';
}

void main() {
  testWidgets('the view subscribes, sizes the session to fit, and sends keys', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    await tester.pumpWidget(MaterialApp(
      theme: buildPromptlyTheme(Brightness.dark),
      home: Scaffold(body: TerminalView(controller: controller)),
    ));
    await tester.pump();
    expect(engine.calls, contains('events'));
    expect(engine.calls.where((c) => c.startsWith('resize')), isNotEmpty, reason: '${engine.calls}');
    final resize = engine.calls.firstWhere((c) => c.startsWith('resize'));
    expect(resize, isNot('resize 80 x 24'));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(engine.calls, contains('write 1'));
    controller.dispose();
  });

  testWidgets('dragging selects, Ctrl+Shift+C copies, typing clears, double click picks a word',
      (tester) async {
    final engine = RecordingEngine()..selection = 'hello';
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildPromptlyTheme(Brightness.dark),
      home: Scaffold(body: TerminalView(controller: controller)),
    ));
    await tester.pump();
    final origin = tester.getTopLeft(find.byType(TerminalView));

    final drag = await tester.startGesture(origin + const Offset(4, 4), kind: PointerDeviceKind.mouse);
    await drag.moveTo(origin + const Offset(160, 4));
    await drag.up();
    await tester.pump();
    expect(engine.calls, contains('select simple 0,0'));
    expect(engine.calls.where((c) => c.startsWith('extend')), isNotEmpty, reason: '${engine.calls}');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, 'hello');
    expect(engine.calls.where((c) => c.startsWith('write')), isEmpty, reason: 'the shortcut is not typed');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(engine.calls, contains('clear'));
    expect(engine.calls.last, 'write 1');

    // Two quick clicks on the same spot ask for a word.
    for (var i = 0; i < 2; i++) {
      final click = await tester.startGesture(origin + const Offset(40, 4), kind: PointerDeviceKind.mouse);
      await click.up();
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(engine.calls.where((c) => c.startsWith('select word')), isNotEmpty, reason: '${engine.calls}');
    controller.dispose();
  });
}
