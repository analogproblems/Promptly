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

  /// What the engine reports as selected text, and as the link under a cell.
  String? selection;
  String? link;

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

  final List<List<int>> written = [];
  @override
  void terminalWrite(int id, List<int> data) {
    calls.add('write ${data.length}');
    written.add(data);
  }

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
  void terminalNotice(int id, String text) => calls.add('notice');
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
  void terminalSearchSet(int id, String? query) => calls.add('search $query');
  @override
  TerminalSearchHit? terminalSearchStep(int id, bool backward) {
    calls.add(backward ? 'step back' : 'step forward');
    return const TerminalSearchHit(index: 2, total: 5, line: 1);
  }

  @override
  String? terminalLinkAt(int id, int col, int line) {
    calls.add('link $col,$line');
    return link;
  }

  @override
  void terminalClose(int id) => calls.add('close');
  @override
  void setDataDir(String path) {}
  @override
  List<ThemeInfo> themesList() => const [];

  @override
  List<CsvHost> csvHostsPreview(String text) => const [];
  @override
  ImportReport csvHostsImport(String text, List<int> rows) => const ImportReport(hosts: 0, keys: 0, skipped: []);
  @override
  List<ThemeInfo> themeImportPreview(String text, String filename) => const [];
  @override
  ThemeInfo themeSave(ThemeInfo theme) => theme;
  @override
  void themeDelete(String id) {}
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
  List<SshForwardStatus> sshForwards(int sessionId) => const [];
  @override
  Future<int> sshForwardSet(int sessionId, int index, bool enabled) async => 0;
  @override
  Future<SshExecResult> sshExec(SshConnectRequest request, String command, int timeoutSeconds) async =>
      const SshExecResult(output: '', exitCode: 0, timedOut: false, error: null);
  @override
  Future<List<Reachability>> hostsReachability(List<ReachTarget> targets, int timeoutMs) async => const [];
  @override
  Future<int> filesOpen(int sessionId) async => 1;
  @override
  void filesClose(int id) {}
  @override
  Future<String> filesHome(int id) async => '/';
  @override
  Future<List<FileEntry>> filesList(int id, String path) async => const [];
  @override
  Future<void> filesMkdir(int id, String path) async {}
  @override
  Future<void> filesRename(int id, String from, String to) async {}
  @override
  Future<void> filesDelete(int id, String path) async {}
  @override
  Future<void> filesChmod(int id, String path, int mode) async {}
  @override
  Future<String> filesReadText(int id, String path) async => '';
  @override
  Future<void> filesWriteText(int id, String path, String text) async {}
  @override
  int filesDownload(int id, String remote, String local) => 1;
  @override
  int filesUpload(int id, String local, String remote) => 1;
  @override
  List<FileTransfer> filesTransfers(int id) => const [];
  @override
  void filesClearTransfers(int id) {}
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
  void secretPut(String id, String kind, String value) {}
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
  @override
  List<SshConfigHost> sshConfigHosts() => const [];
  @override
  ImportReport sshConfigImport(List<String> aliases) => throw UnimplementedError();
  @override
  SyncStatus syncStatus() => throw UnimplementedError();
  @override
  Stream<SyncStatus> syncEvents() => const Stream.empty();
  @override
  bool syncFolderHasVault(String path) => false;
  @override
  String syncDefaultDeviceName() => 'test';
  @override
  Future<SyncSetupResult> syncCreateLocalFolder(String path, String passphrase, String deviceName) =>
      throw UnimplementedError();
  @override
  Future<void> syncJoinLocalFolder(
    String path, {
    String? passphrase,
    String? recoveryCode,
    required String deviceName,
  }) => throw UnimplementedError();
  @override
  Future<bool> syncSftpFolderHasVault(String hostId, String remoteDir) async => false;
  @override
  Future<SyncSetupResult> syncCreateSftp(String hostId, String remoteDir, String passphrase, String deviceName) =>
      throw UnimplementedError();
  @override
  Future<void> syncJoinSftp(
    String hostId,
    String remoteDir, {
    String? passphrase,
    String? recoveryCode,
    required String deviceName,
  }) => throw UnimplementedError();
  @override
  Future<SyncStatus> syncNow() => throw UnimplementedError();
  @override
  void syncDisconnect() {}
  @override
  Future<void> syncRemoveDevice(String deviceRecordId) async {}
  @override
  String? syncQrPayload() => null;
}

void main() {
  testWidgets('Ctrl+click opens a link, Ctrl+Shift+F asks for the search bar', (tester) async {
    final engine = RecordingEngine()..link = 'https://example.com/docs';
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    String? opened;
    var findAsked = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(
          body: TerminalView(controller: controller, onFind: () => findAsked++, onOpenLink: (uri) => opened = uri),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(findAsked, 1);
    expect(engine.calls.where((c) => c.startsWith('write')), isEmpty, reason: 'the shortcut is not typed');

    // Control is still held: a click asks the engine for the link and opens it.
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final gesture = await tester.startGesture(origin + const Offset(4, 4), kind: PointerDeviceKind.mouse);
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(engine.calls, contains('link 0,0'));
    expect(opened, 'https://example.com/docs');
    expect(
      engine.calls.where((c) => c.startsWith('select')),
      isEmpty,
      reason: 'opening a link does not start a selection',
    );
    controller.dispose();
  });

  testWidgets('the view subscribes, sizes the session to fit, and sends keys', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(body: TerminalView(controller: controller)),
      ),
    );
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

  testWidgets('dragging selects, Ctrl+Shift+C copies, typing clears, double click picks a word', (tester) async {
    final engine = RecordingEngine()..selection = 'hello';
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(body: TerminalView(controller: controller)),
      ),
    );
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

  testWidgets('the soft keyboard types into the session, Enter is Return, sticky Ctrl makes control bytes', (
    tester,
  ) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(body: TerminalView(controller: controller, imeInput: true)),
      ),
    );
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: 'focus attaches the IME');

    void ime(String text) => tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );

    ime(' ls');
    await tester.pump();
    expect(engine.written.last, 'ls'.codeUnits);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(engine.written.last, [13]);

    // Backspace in the IME erases what was typed.
    ime(' ab');
    await tester.pump();
    expect(engine.written.last, 'ab'.codeUnits);
    // The buffer is reset to its one-space sentinel after each commit, so a
    // backspace empties it, and that is how it reaches the program.
    ime('');
    await tester.pump();
    expect(engine.written.last, [0x7f]);

    // A hardware key for a printable character is left to the IME (no double input).
    final before = engine.written.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(engine.written.length, before);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(engine.written.last, [0x1b, 0x5b, 0x41], reason: 'keys the IME lacks still come from key events');

    controller.setSticky(ctrl: true);
    ime(' c');
    await tester.pump();
    expect(engine.written.last, [3]);
    expect(controller.stickyCtrl, isFalse, reason: 'sticky modifiers are one-shot');
    controller.dispose();
  });
}
