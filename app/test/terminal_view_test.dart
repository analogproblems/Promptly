import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/platform.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/features/terminal/key_mapper.dart';
import 'package:promptly/features/terminal/terminal_controller.dart';
import 'package:promptly/features/terminal/terminal_grid.dart';
import 'package:promptly/features/terminal/terminal_painter.dart';
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
  SecretsState secretsState() => SecretsState.encrypted;
  @override
  EndpointParse parseEndpoint(String input) => const EndpointError('n/a');
  @override
  int terminalOpenLocal({required int cols, required int rows, required String theme}) => 1;
  @override
  void terminalSetScrollback(int lines) => calls.add('scrollback $lines');
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

  final List<String> pasted = [];
  @override
  void terminalPaste(int id, String text) {
    calls.add('paste');
    pasted.add(text);
  }

  /// Whether the "program" takes mouse events.
  bool takesMouse = false;
  @override
  bool terminalMouse(
    int id,
    TerminalMouseAction action,
    TerminalMouseButton? button,
    int col,
    int row, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    if (!takesMouse) return false;
    calls.add('mouse ${action.name} ${button?.name} $col,$row');
    return true;
  }
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
  TerminalLink? terminalLinkAt(int id, int col, int line) {
    calls.add('link $col,$line');
    return link == null ? null : TerminalLink(uri: link!, hidden: false);
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
  Future<String> sshInstallPublicKey(SshConnectRequest request, String publicKey) async => '';
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
  int filesDownload(int id, String remote, String local, {required bool replace}) => 1;
  @override
  int filesUpload(int id, String local, String remote, {required bool replace}) => 1;
  @override
  void filesCancelTransfer(int id, int transfer) {}
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
  String keyExport(String privateKey, {String? passphrase, String? newPassphrase}) => throw UnimplementedError();
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
    String? joinCode,
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
    String? joinCode,
    required String deviceName,
  }) => throw UnimplementedError();
  @override
  Future<SyncStatus> syncNow() => throw UnimplementedError();
  @override
  void syncWake() {}
  @override
  Future<void> syncUnlock({String? passphrase, String? recoveryCode}) => throw UnimplementedError();
  @override
  Future<SyncSetupResult> syncRecreateVault(String passphrase) => throw UnimplementedError();
  @override
  Future<void> syncDisconnect() async {}
  @override
  Future<void> syncRemoveDevice(String deviceRecordId) async {}
  @override
  Future<SyncSetupResult> syncRotateKey(String passphrase) => throw UnimplementedError();
  @override
  String? syncQrPayload() => null;
  @override
  PassphraseCheck syncPassphraseCheck(String passphrase) => throw UnimplementedError();
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
          body: TerminalView(controller: controller, onFind: () => findAsked++, onOpenLink: (l) => opened = l.uri),
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

  testWidgets('Caps Lock can type Escape and Cmd can be Ctrl, as Settings says', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    Future<void> show(KeyOptions keys) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPromptlyTheme(Brightness.dark),
          home: Scaffold(body: TerminalView(controller: controller, keys: keys)),
        ),
      );
      await tester.pump();
      engine.written.clear();
    }

    await show(const KeyOptions(capsLockAsEscape: true, cmdAsCtrl: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
    expect(engine.written, [
      [0x1b],
    ]);
    // The system turned Caps Lock on all the same: letters follow Shift alone.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'A');
    expect(engine.written.last, [0x61]);
    await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
    engine.written.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(engine.written, [
      [0x03],
    ], reason: 'Cmd+C stops a program, as Ctrl+C does');

    // Without them, Caps Lock types nothing and Cmd+C copies.
    await show(const KeyOptions());
    await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
    await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(engine.written, isEmpty);
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

    // A letter key goes on to the system's text input, which types it.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: ' a', selection: TextSelection.collapsed(offset: 2)),
    );
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

  testWidgets('a program that asks for the mouse gets clicks, drags and the wheel; Shift selects', (tester) async {
    final engine = RecordingEngine()..takesMouse = true;
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(body: TerminalView(controller: controller)),
      ),
    );
    await tester.pump();
    controller.grid
      ..cols = 80
      ..rows = 24
      ..mouseReporting = true;
    final origin = tester.getTopLeft(find.byType(TerminalView));

    final drag = await tester.startGesture(origin + const Offset(2, 2), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(40, 0));
    await drag.up();
    await tester.pump();
    final mouse = engine.calls.where((c) => c.startsWith('mouse')).toList();
    expect(mouse.first, 'mouse press left 0,0');
    expect(mouse.where((c) => c.startsWith('mouse move left')), isNotEmpty, reason: '$mouse');
    expect(mouse.last, startsWith('mouse release left'));
    expect(engine.calls.where((c) => c.startsWith('select')), isEmpty, reason: 'no local selection');

    await tester.sendEventToBinding(
      PointerScrollEvent(position: origin + const Offset(2, 2), scrollDelta: const Offset(0, 200)),
    );
    await tester.pump();
    expect(engine.calls.last, 'mouse wheelDown null 0,0');
    expect(engine.calls.where((c) => c.startsWith('scroll')), isEmpty, reason: 'the program scrolls, not us');

    // Shift overrides: a local selection as usual.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final pick = await tester.startGesture(origin + const Offset(2, 2), kind: PointerDeviceKind.mouse);
    await pick.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(engine.calls.where((c) => c.startsWith('select')), isNotEmpty);
    controller.dispose();
  });

  testWidgets('moving the mouse without a button is passed on once per cell', (tester) async {
    final engine = RecordingEngine()..takesMouse = true;
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(body: TerminalView(controller: controller)),
      ),
    );
    await tester.pump();
    controller.grid
      ..cols = 80
      ..rows = 24
      ..mouseReporting = true;
    final origin = tester.getTopLeft(find.byType(TerminalView));

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: origin + const Offset(2, 2));
    await pointer.moveTo(origin + const Offset(2, 2));
    await pointer.moveTo(origin + const Offset(3, 3));
    await pointer.moveTo(origin + const Offset(40, 2));
    await tester.pump();
    final moves = engine.calls.where((c) => c.startsWith('mouse move null')).toList();
    expect(moves, hasLength(2), reason: 'one per cell: $moves');
    expect(moves.first, 'mouse move null 0,0');
    await pointer.removePointer();
    controller.dispose();
  });


  testWidgets('a paste through the soft keyboard is checked first and sent as a paste', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    final asked = <String>[];
    String? answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(
          body: TerminalView(
            controller: controller,
            imeInput: true,
            confirmPaste: (text) async {
              asked.add(text);
              return answer;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final client = tester.state(find.byType(TerminalView)) as DeltaTextInputClient;
    void insert(String text) => client.updateEditingValueWithDeltas([
          TextEditingDeltaInsertion(
            oldText: ' ',
            textInserted: text,
            insertionOffset: 1,
            selection: TextSelection.collapsed(offset: 1 + text.length),
            composing: TextRange.empty,
          ),
        ]);

    // Cancelled: nothing at all reaches the program.
    final writes = engine.written.length;
    insert('echo one\necho two\n');
    await tester.pump();
    expect(asked, ['echo one\necho two\n']);
    expect(engine.written.length, writes);
    expect(engine.pasted, isEmpty);

    // Confirmed: sent as a paste, where the engine cleans and brackets it.
    answer = 'echo one\necho two';
    insert('echo one\necho two\n');
    await tester.pump();
    expect(engine.pasted, ['echo one\necho two']);
    expect(engine.written.length, writes);

    // The whole-value fallback goes the same way.
    client.updateEditingValue(const TextEditingValue(text: ' a\nb'));
    await tester.pump();
    expect(asked.last, 'a\nb');

    // Enter on its own is still Return, and stray control characters
    // from a keyboard are dropped.
    insert('\n');
    expect(engine.written.last, [13]);
    insert('x\x1b[201~y');
    expect(engine.written.last, 'x[201~y'.codeUnits);
    controller.dispose();
  });

  testWidgets('a keyboard paste that replaces typed text erases nothing until it is accepted', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    Completer<String?>? answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(
          body: TerminalView(
            controller: controller,
            imeInput: true,
            confirmPaste: (text) => (answer = Completer<String?>()).future,
          ),
        ),
      ),
    );
    await tester.pump();
    final client = tester.state(find.byType(TerminalView)) as DeltaTextInputClient;
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' ',
        textInserted: 'abc',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    ]);
    final typed = engine.written.length;
    void replaceAbc() => client.updateEditingValueWithDeltas([
          const TextEditingDeltaReplacement(
            oldText: ' abc',
            replacementText: 'one\ntwo',
            replacedRange: TextRange(start: 1, end: 4),
            selection: TextSelection.collapsed(offset: 8),
            composing: TextRange.empty,
          ),
        ]);

    // While the check is up, and after Cancel, nothing is erased or sent,
    // and typing meanwhile waits behind the paste.
    replaceAbc();
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' one\ntwo',
        textInserted: 'x',
        insertionOffset: 8,
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange.empty,
      ),
    ]);
    await tester.pump();
    expect(engine.written.length, typed);
    answer!.complete(null);
    await tester.pump();
    expect(engine.written.sublist(typed), ['x'.codeUnits]);
    expect(engine.pasted, isEmpty);

    // Accepted: the replaced text is erased, then the paste goes in.
    final before = engine.written.length;
    final calls = engine.calls.length;
    replaceAbc();
    answer!.complete('one\ntwo');
    await tester.pump();
    expect(engine.written.sublist(before), [
      [0x7f, 0x7f, 0x7f],
    ]);
    expect(engine.calls.sublist(calls).last, 'paste');
    expect(engine.pasted, ['one\ntwo']);

    // The whole-value fallback holds its erasure back the same way.
    final whole = engine.written.length;
    client.updateEditingValue(const TextEditingValue(text: ' ab'));
    client.updateEditingValue(const TextEditingValue(text: ' a\nb'));
    await tester.pump();
    expect(engine.written.length, whole + 1); // typing "ab" only
    answer!.complete(null);
    await tester.pump();
    expect(engine.written.length, whole + 1);
    controller.dispose();
  });

  testWidgets('a keyboard paste sent as a deletion then an insertion is checked as one change', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    final asked = <String>[];
    Completer<String?>? answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(
          body: TerminalView(
            controller: controller,
            imeInput: true,
            confirmPaste: (text) {
              asked.add(text);
              return (answer = Completer<String?>()).future;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final client = tester.state(find.byType(TerminalView)) as DeltaTextInputClient;
    void type(String text) => client.updateEditingValueWithDeltas([
          TextEditingDeltaInsertion(
            oldText: ' ',
            textInserted: text,
            insertionOffset: 1,
            selection: TextSelection.collapsed(offset: 1 + text.length),
            composing: TextRange.empty,
          ),
        ]);
    // What Android sends for Paste over a selection: delete it, then insert.
    void pasteOver(String old, String text) => client.updateEditingValueWithDeltas([
          TextEditingDeltaDeletion(
            oldText: ' $old',
            deletedRange: TextRange(start: 1, end: 1 + old.length),
            selection: const TextSelection.collapsed(offset: 1),
            composing: TextRange.empty,
          ),
          TextEditingDeltaInsertion(
            oldText: ' ',
            textInserted: text,
            insertionOffset: 1,
            selection: TextSelection.collapsed(offset: 1 + text.length),
            composing: TextRange.empty,
          ),
        ]);

    type('abc');
    final typed = engine.written.length;
    pasteOver('abc', 'one\ntwo');
    await tester.pump();
    expect(asked, ['one\ntwo']);
    expect(engine.written.length, typed);
    answer!.complete(null);
    await tester.pump();
    expect(engine.written.length, typed);
    expect(engine.pasted, isEmpty);

    // Accepted: one erase of the old text, then the paste.
    type('abc');
    final before = engine.written.length;
    pasteOver('abc', 'one\ntwo');
    answer!.complete('one\ntwo');
    await tester.pump();
    expect(engine.written.sublist(before), [
      [0x7f, 0x7f, 0x7f],
    ]);
    expect(engine.pasted, ['one\ntwo']);

    // A paste that starts like the text it replaces is still shown whole.
    type('one');
    pasteOver('one', 'one\ntwo');
    expect(asked.last, 'one\ntwo');
    answer!.complete(null);
    await tester.pump();

    // A plain Backspace still goes straight through.
    final erased = engine.written.length;
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaDeletion(
        oldText: ' x',
        deletedRange: TextRange(start: 1, end: 2),
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.sublist(erased), [
      [0x7f],
    ]);
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
    final client = tester.state(find.byType(TerminalView)) as DeltaTextInputClient;

    // Deltas, as the platform sends them: what was inserted or deleted.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' ',
        textInserted: 'ls',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.last, 'ls'.codeUnits);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(engine.written.last, [13]);

    // Backspace is a deletion delta, whatever the buffer holds.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaDeletion(
        oldText: ' ls',
        deletedRange: TextRange(start: 2, end: 3),
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.last, [0x7f]);

    // A key that the platform applied to a buffer we had already reset
    // still arrives as its own insertion: nothing is doubled or lost.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' lx',
        textInserted: 's',
        insertionOffset: 3,
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.last, 's'.codeUnits);

    // A hardware key for a printable character is left to the IME (no double input).
    final before = engine.written.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(engine.written.length, before);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(engine.written.last, [0x1b, 0x5b, 0x41], reason: 'keys the IME lacks still come from key events');

    // Whole-value updates (a platform without deltas, or a test) work too.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: ' lxs', selection: TextSelection.collapsed(offset: 4)),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: ' lxsa', selection: TextSelection.collapsed(offset: 5)),
    );
    await tester.pump();
    expect(engine.written.last, 'a'.codeUnits);

    controller.setSticky(ctrl: true);
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' lxsa',
        textInserted: 'c',
        insertionOffset: 5,
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.last, [3]);
    expect(controller.stickyCtrl, isFalse, reason: 'sticky modifiers are one-shot');
    controller.dispose();
  });

  testWidgets('on a computer, an input method composes at the cursor and only what it commits is typed', (
    tester,
  ) async {
    touchPlatformOverride = false;
    addTearDown(() => touchPlatformOverride = null);
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    final asked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(
          body: TerminalView(
            controller: controller,
            confirmPaste: (text) async {
              asked.add(text);
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: 'a computer attaches its input method too');
    final client = tester.state(find.byType(TerminalView)) as DeltaTextInputClient;
    String composing() => (tester
            .widget<CustomPaint>(find.descendant(of: find.byType(TerminalView), matching: find.byType(CustomPaint)))
            .painter! as TerminalPainter)
        .composing;

    // Pinyin: "ni" is being composed; the program sees nothing of it, and
    // it shows at the cursor.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' ',
        textInserted: 'n',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 2),
      ),
    ]);
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' n',
        textInserted: 'i',
        insertionOffset: 2,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 1, end: 3),
      ),
    ]);
    await tester.pump();
    expect(engine.written, isEmpty);
    expect(composing(), 'ni');

    // Meanwhile keys are the input method's: Backspace and the arrows work
    // on the composition, not on the command line.
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(engine.written, isEmpty);

    // Its list of candidates opens at the cursor: the first cell, after
    // the inset.
    final placed = tester.testTextInput.log.where((c) => c.method == 'TextInput.setMarkedTextRect').toList();
    expect(placed, isNotEmpty);
    expect((placed.last.arguments as Map)['x'], 8.0);
    expect((placed.last.arguments as Map)['y'], 0.0);
    expect(tester.testTextInput.log.map((c) => c.method), contains('TextInput.setEditableSizeAndTransform'));

    // Committed: the characters are typed, once.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaReplacement(
        oldText: ' ni',
        replacementText: '你',
        replacedRange: TextRange(start: 1, end: 3),
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
    ]);
    await tester.pump();
    expect(engine.written, [utf8.encode('你')]);
    expect(composing(), isEmpty);

    // An accent waiting for its letter (a dead key) goes the same way.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' 你',
        textInserted: '´',
        insertionOffset: 2,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 2, end: 3),
      ),
    ]);
    expect(engine.written, hasLength(1));
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaReplacement(
        oldText: ' 你´',
        replacementText: 'é',
        replacedRange: TextRange(start: 2, end: 3),
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.last, utf8.encode('é'));

    // Plain keys work as before: Enter and the arrows straight from the
    // key, a letter through the text input, typed at once.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(engine.written.last, [13]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(engine.written.last, [0x1b, 0x5b, 0x41]);
    final typed = engine.written.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(engine.written.length, typed, reason: 'left to the input method');
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' 你é',
        textInserted: 'a',
        insertionOffset: 3,
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.last, 'a'.codeUnits);

    // A commit with line breaks in it is a paste, and is checked first.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' 你éa',
        textInserted: 'x',
        insertionOffset: 4,
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 4, end: 5),
      ),
    ]);
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaReplacement(
        oldText: ' 你éax',
        replacementText: 'one\ntwo',
        replacedRange: TextRange(start: 4, end: 5),
        selection: TextSelection.collapsed(offset: 11),
        composing: TextRange.empty,
      ),
    ]);
    await tester.pump();
    expect(asked, ['one\ntwo']);
    expect(engine.pasted, isEmpty, reason: 'cancelled');
    expect(engine.written.last, 'a'.codeUnits);
    controller.dispose();
  });

  testWidgets('a phone keyboard suggests and corrects words only when Settings says so', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    Widget view({required bool autocorrect}) => MaterialApp(
      theme: buildPromptlyTheme(Brightness.dark),
      home: Scaffold(body: TerminalView(controller: controller, imeInput: true, autocorrect: autocorrect)),
    );
    await tester.pumpWidget(view(autocorrect: false));
    await tester.pump();
    expect(tester.testTextInput.setClientArgs!['autocorrect'], isFalse);
    expect(tester.testTextInput.setClientArgs!['enableSuggestions'], isFalse);

    await tester.pumpWidget(view(autocorrect: true));
    await tester.pump();
    expect(tester.testTextInput.setClientArgs!['autocorrect'], isTrue);
    expect(tester.testTextInput.setClientArgs!['enableSuggestions'], isTrue);

    // On a phone a word is typed as it is composed, and a correction
    // erases it and types the corrected one.
    touchPlatformOverride = true;
    addTearDown(() => touchPlatformOverride = null);
    final client = tester.state(find.byType(TerminalView)) as DeltaTextInputClient;
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' ',
        textInserted: 'teh',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 1, end: 4),
      ),
    ]);
    expect(engine.written.last, 'teh'.codeUnits);
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaReplacement(
        oldText: ' teh',
        replacementText: 'the',
        replacedRange: TextRange(start: 1, end: 4),
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.sublist(engine.written.length - 2), [
      [0x7f, 0x7f, 0x7f],
      'the'.codeUnits,
    ]);
    controller.dispose();
  });

  testWidgets('soft keyboard backspace erases whole emoji and keeps working once the buffer is empty', (tester) async {
    final engine = RecordingEngine();
    final controller = TerminalController(engine: engine, id: 1, label: 'test');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPromptlyTheme(Brightness.dark),
        home: Scaffold(body: TerminalView(controller: controller, imeInput: true)),
      ),
    );
    await tester.pump();
    final client = tester.state(find.byType(TerminalView)) as DeltaTextInputClient;

    // An emoji is two UTF-16 units but one character to the shell.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaInsertion(
        oldText: ' ',
        textInserted: 'a😀',
        insertionOffset: 1,
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    ]);
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaDeletion(
        oldText: ' a😀',
        deletedRange: TextRange(start: 2, end: 4),
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
    ]);
    expect(engine.written.last, [0x7f], reason: 'one erase, so the "a" survives');

    // Backspace past the start (a command recalled from history): each one
    // still reaches the shell, because the buffer is refilled.
    client.updateEditingValueWithDeltas([
      const TextEditingDeltaDeletion(
        oldText: ' a',
        deletedRange: TextRange(start: 1, end: 2),
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange.empty,
      ),
    ]);
    for (var i = 0; i < 3; i++) {
      final count = engine.written.length;
      expect(client.currentTextEditingValue!.text, ' ');
      client.updateEditingValueWithDeltas([
        const TextEditingDeltaDeletion(
          oldText: ' ',
          deletedRange: TextRange(start: 0, end: 1),
          selection: TextSelection.collapsed(offset: 0),
          composing: TextRange.empty,
        ),
      ]);
      expect(engine.written.length, count + 1);
      expect(engine.written.last, [0x7f]);
    }
    controller.dispose();
  });

  group('touch', () {
    Future<TerminalController> touchView(
      WidgetTester tester,
      RecordingEngine engine, {
      void Function(TerminalLink link)? onOpenLink,
      void Function(int step)? onSwitchSession,
    }) async {
      final controller = TerminalController(engine: engine, id: 1, label: 'test');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPromptlyTheme(Brightness.dark),
          home: Scaffold(
            body: TerminalView(controller: controller, onOpenLink: onOpenLink, onSwitchSession: onSwitchSession),
          ),
        ),
      );
      await tester.pump();
      controller.grid
        ..cols = 80
        ..rows = 24;
      return controller;
    }

    testWidgets('a tap is a click for a program that asks for the mouse, and nothing otherwise', (tester) async {
      final engine = RecordingEngine();
      final controller = await touchView(tester, engine);
      final origin = tester.getTopLeft(find.byType(TerminalView));

      await tester.tapAt(origin + const Offset(10, 4));
      await tester.pump();
      expect(engine.calls.where((c) => c.startsWith('mouse') || c.startsWith('select')), isEmpty);

      engine.takesMouse = true;
      controller.grid.mouseReporting = true;
      await tester.tapAt(origin + const Offset(10, 40));
      await tester.pump();
      final mouse = engine.calls.where((c) => c.startsWith('mouse')).toList();
      expect(mouse, hasLength(2), reason: '$mouse');
      expect(mouse.first, startsWith('mouse press left 0,'));
      expect(mouse.last, startsWith('mouse release left 0,'));
      expect(mouse.first, isNot('mouse press left 0,0'), reason: 'the row under the finger');

      // A finger that moves is not a tap.
      final drag = await tester.startGesture(origin + const Offset(10, 4));
      await drag.moveBy(const Offset(0, 60));
      await drag.up();
      await tester.pump();
      expect(engine.calls.where((c) => c.startsWith('mouse')), hasLength(2));
    });

    testWidgets('a tap on a link, path or address offers to open or copy it', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final engine = RecordingEngine()
        ..link = 'https://example.com/docs'
        ..takesMouse = true;
      String? opened;
      final controller = await touchView(tester, engine, onOpenLink: (l) => opened = l.uri);
      // A program has the mouse, but a link still wins: a phone has no Ctrl.
      controller.grid
        ..mouseReporting = true
        ..lines = [GridRow.blank(80, 0, 0)..flags[0] = CellFlags.link];
      final origin = tester.getTopLeft(find.byType(TerminalView));

      await tester.tapAt(origin + const Offset(10, 4));
      await tester.pumpAndSettle();
      expect(find.text('Open link'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      expect(engine.calls.where((c) => c.startsWith('mouse')), isEmpty);
      await tester.tap(find.text('Open link'));
      await tester.pumpAndSettle();
      expect(opened, 'https://example.com/docs');

      engine.link = '/var/log/syslog';
      await tester.tapAt(origin + const Offset(10, 4));
      await tester.pumpAndSettle();
      expect(find.text('Open link'), findsNothing, reason: 'a path means something on the other machine');
      await tester.tap(find.text('Copy path'));
      await tester.pumpAndSettle();
      expect(copied, '/var/log/syslog');
    });

    testWidgets('a double tap selects a word and offers to copy it', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final engine = RecordingEngine()..selection = 'deploy';
      await touchView(tester, engine);
      final origin = tester.getTopLeft(find.byType(TerminalView));

      await tester.tapAt(origin + const Offset(30, 4));
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.calls.where((c) => c.startsWith('select')), isEmpty, reason: 'one tap selects nothing');
      await tester.tapAt(origin + const Offset(32, 4));
      await tester.pumpAndSettle();
      expect(engine.calls.where((c) => c.startsWith('select word')), hasLength(1), reason: '${engine.calls}');
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, 'deploy');
    });

    testWidgets('pinching changes the text size, in whole steps', (tester) async {
      final engine = RecordingEngine();
      final controller = await touchView(tester, engine);
      final sizes = <double>[];
      controller.onFontSize = sizes.add;
      final centre = tester.getCenter(find.byType(TerminalView));

      final a = await tester.startGesture(centre - const Offset(50, 0), pointer: 1);
      final b = await tester.startGesture(centre + const Offset(50, 0), pointer: 2);
      await a.moveBy(const Offset(-25, 0));
      await b.moveBy(const Offset(25, 0));
      await a.up();
      await b.up();
      await tester.pump();
      expect(controller.fontSize, 21, reason: 'fingers half as far apart again: 14 × 1.5');
      expect(sizes.last, 21);
      expect(sizes.every((s) => s == s.roundToDouble()), isTrue, reason: '$sizes');

      final c = await tester.startGesture(centre - const Offset(80, 0), pointer: 3);
      final d = await tester.startGesture(centre + const Offset(80, 0), pointer: 4);
      await c.moveBy(const Offset(60, 0));
      await d.moveBy(const Offset(-60, 0));
      await c.up();
      await d.up();
      await tester.pump();
      expect(controller.fontSize, 8, reason: 'never smaller than the smallest size');
      expect(engine.calls.where((c) => c.startsWith('mouse') || c.startsWith('select')), isEmpty);
    });

    testWidgets('two fingers swiped sideways switch sessions', (tester) async {
      final engine = RecordingEngine();
      final steps = <int>[];
      final controller = await touchView(tester, engine, onSwitchSession: steps.add);
      final centre = tester.getCenter(find.byType(TerminalView));

      Future<void> swipe(double dx) async {
        final a = await tester.startGesture(centre + const Offset(-20, -20), pointer: 1);
        final b = await tester.startGesture(centre + const Offset(20, 20), pointer: 2);
        // In small steps, as a screen reports them, one finger at a time.
        for (var i = 0; i < 12; i++) {
          await a.moveBy(Offset(dx / 12, 0));
          await b.moveBy(Offset(dx / 12, 0));
        }
        await a.up();
        await b.up();
        await tester.pump();
      }

      await swipe(-120);
      expect(steps, [1], reason: 'once per swipe, to the next session');
      await swipe(120);
      expect(steps, [1, -1]);
      expect(controller.fontSize, 14, reason: 'a swipe is not a pinch');

      // Two fingers moving up and down are neither.
      final a = await tester.startGesture(centre + const Offset(-20, 0), pointer: 1);
      final b = await tester.startGesture(centre + const Offset(20, 0), pointer: 2);
      for (var i = 0; i < 12; i++) {
        await a.moveBy(const Offset(0, 10));
        await b.moveBy(const Offset(0, 10));
      }
      await a.up();
      await b.up();
      await tester.pump();
      expect(steps, [1, -1]);
      expect(controller.fontSize, 14);
    });
  });
}
