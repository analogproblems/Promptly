import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/app.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/file_picker.dart';
import 'package:promptly/core/platform.dart';
import 'package:promptly/features/files/files_screen.dart';
import 'package:promptly/features/files/fs.dart';
import 'package:promptly/features/terminal/keyboard_bar.dart';
import 'package:promptly/features/sessions/session_body.dart';
import 'package:promptly/features/sessions/session_thumbnail.dart';
import 'package:promptly/features/workspace/workspace.dart';
import 'package:promptly/features/workspace/workspace_screen.dart';

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

  /// Notices shown in sessions, and every SSH request begun.
  final List<String> notices = [];
  final List<SshConnectRequest> requests = [];

  /// When true, a session's stream ends with a drop (exit without a code)
  /// right after its first frame.
  bool dropAfterFrame = false;

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

  /// Frames pushed after the first one, by `emitText`.
  final StreamController<TerminalEvent> laterFrames = StreamController<TerminalEvent>.broadcast();

  /// Show `text` on the top row of a session, as a program printing it would.
  void emitText(int id, String text) {
    final glyphs = List<String>.generate(frameCols, (i) => i < text.length ? text[i] : '');
    laterFrames.add(
      TerminalEvent(
        kind: TerminalEventKind.frame,
        frame: TerminalFrame(
          cols: frameCols,
          rows: frameRows,
          full: false,
          rowsChanged: [
            TerminalRow(
              line: 0,
              glyphs: glyphs,
              fg: Uint32List(frameCols),
              bg: Uint32List(frameCols),
              flags: Uint16List(frameCols),
            ),
          ],
          cursor: TerminalCursor(line: 0, col: text.length, shape: TerminalCursorShape.block),
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
    );
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
    final first = [
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
      if (dropAfterFrame)
        const TerminalEvent(kind: TerminalEventKind.exited, frame: null, clipboard: null, exitCode: null),
    ];
    Stream<TerminalEvent> events() async* {
      yield* Stream.fromIterable(first);
      if (!dropAfterFrame) yield* laterFrames.stream;
    }

    return events();
  }

  /// Everything typed or pasted into sessions.
  final List<List<int>> written = [];
  final List<String> pasted = [];

  @override
  void terminalWrite(int id, List<int> data) => written.add(data);
  @override
  void terminalPaste(int id, String text) => pasted.add(text);
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
  void terminalNotice(int id, String text) => notices.add(text);
  @override
  void terminalSelectBegin(int id, int col, int line, bool sideRight, TerminalSelectKind kind) {}
  @override
  void terminalSelectUpdate(int id, int col, int line, bool sideRight) {}
  @override
  void terminalSelectClear(int id) {}
  @override
  String? terminalSelectionText(int id) => null;

  /// Search queries and steps, in order; a non-empty query finds 2 of 5.
  final List<String> searchCalls = [];
  String? _query;

  @override
  void terminalSearchSet(int id, String? query) {
    searchCalls.add('search $query');
    _query = query;
  }

  @override
  TerminalSearchHit? terminalSearchStep(int id, bool backward) {
    searchCalls.add(backward ? 'step back' : 'step forward');
    return _query == null ? null : const TerminalSearchHit(index: 2, total: 5, line: 1);
  }

  @override
  String? terminalLinkAt(int id, int col, int line) => null;
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
    builtin: true,
  );

  @override
  List<ThemeInfo> themesList() => [
    _theme('promptly-dark', 'Promptly Dark', true, 0x0E1116, 0xE6EDF3),
    _theme('promptly-light', 'Promptly Light', false, 0xFAFAF7, 0x1F2328),
    _theme('dracula', 'Dracula', true, 0x282A36, 0xF8F8F2),
    ...customThemes,
  ];

  /// When set, SSH attempts succeed with this engine session id, and that
  /// session emits one full frame of the given size.
  int? connectedSessionId;
  int frameCols = 142;
  int frameRows = 37;

  @override
  int sshConnectBegin(SshConnectRequest request) {
    requests.add(request);
    return requests.length;
  }

  @override
  Stream<SshEvent> sshConnectEvents(int attemptId) {
    final id = connectedSessionId;
    if (id == null) return const Stream.empty();
    return Stream.fromIterable([
      const SshEvent(
        kind: SshEventKind.progress,
        step: SshStep.connecting,
        hostKey: null,
        secretPrompt: null,
        kbName: null,
        kbInstructions: null,
        kbPrompts: null,
        sessionId: null,
        error: null,
      ),
      SshEvent(
        kind: SshEventKind.connected,
        step: null,
        hostKey: null,
        secretPrompt: null,
        kbName: null,
        kbInstructions: null,
        kbPrompts: null,
        sessionId: id,
        error: null,
      ),
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

  /// Canned results for snippets run on hosts, by hostname, and the calls made.
  final Map<String, SshExecResult> execResults = {};
  final List<String> execCalls = [];

  @override
  Future<SshExecResult> sshExec(SshConnectRequest request, String command, int timeoutSeconds) async {
    execCalls.add('${request.host} $command');
    return execResults[request.host] ??
        SshExecResult(output: '', exitCode: null, timedOut: false, error: 'no result for ${request.host}');
  }

  /// What the reachability knock reports, by hostname.
  final Map<String, (bool, int)> reach = {};

  @override
  Future<List<Reachability>> hostsReachability(List<ReachTarget> targets, int timeoutMs) async => [
    for (final t in targets)
      Reachability(id: t.id, reachable: reach[t.host]?.$1 ?? false, millis: reach[t.host]?.$2 ?? 0),
  ];

  /// A small remote file tree for the browser, by folder, and every change
  /// and transfer asked for.
  final Map<String, List<FileEntry>> remoteFiles = {
    '/home/ops': [
      FileEntry(
        name: 'projects',
        isDir: true,
        isSymlink: false,
        size: BigInt.zero,
        modified: BigInt.zero,
        permissions: 0x1ED,
        owner: 'ops',
        group: 'ops',
      ),
      FileEntry(
        name: 'notes.txt',
        isDir: false,
        isSymlink: false,
        size: BigInt.from(2048),
        modified: BigInt.zero,
        permissions: 0x1A4,
        owner: 'ops',
        group: 'ops',
      ),
    ],
    '/home/ops/projects': [
      FileEntry(
        name: 'app.py',
        isDir: false,
        isSymlink: false,
        size: BigInt.from(512),
        modified: BigInt.zero,
        permissions: 0x1A4,
        owner: 'ops',
        group: 'ops',
      ),
    ],
  };
  final List<String> fileCalls = [];
  final List<FileTransfer> transfers = [];

  @override
  Future<int> filesOpen(int sessionId) async {
    fileCalls.add('open $sessionId');
    return 3;
  }

  @override
  void filesClose(int id) => fileCalls.add('close $id');
  @override
  Future<String> filesHome(int id) async => '/home/ops';
  @override
  Future<List<FileEntry>> filesList(int id, String path) async =>
      remoteFiles[path] ?? (throw 'That is not there any more.');
  @override
  Future<void> filesMkdir(int id, String path) async => fileCalls.add('mkdir $path');
  @override
  Future<void> filesRename(int id, String from, String to) async => fileCalls.add('rename $from $to');
  @override
  Future<void> filesDelete(int id, String path) async => fileCalls.add('delete $path');
  @override
  Future<void> filesChmod(int id, String path, int mode) async => fileCalls.add('chmod $path ${mode.toRadixString(8)}');

  /// What remote text files hold, by path.
  final Map<String, String> remoteText = {};

  @override
  Future<String> filesReadText(int id, String path) async {
    fileCalls.add('read $path');
    return remoteText[path] ?? (throw 'not a text file');
  }

  @override
  Future<void> filesWriteText(int id, String path, String text) async {
    fileCalls.add('write $path');
    remoteText[path] = text;
  }

  @override
  int filesDownload(int id, String remote, String local) {
    fileCalls.add('download $remote $local');
    transfers.add(
      FileTransfer(
        id: transfers.length + 1,
        name: remote.split('/').last,
        upload: false,
        done: BigInt.from(2048),
        total: BigInt.from(2048),
        finished: true,
        error: null,
      ),
    );
    return transfers.length;
  }

  @override
  int filesUpload(int id, String local, String remote) {
    fileCalls.add('upload $local $remote');
    transfers.add(
      FileTransfer(
        id: transfers.length + 1,
        name: remote.split('/').last,
        upload: true,
        done: BigInt.from(10),
        total: BigInt.from(10),
        finished: true,
        error: null,
      ),
    );
    return transfers.length;
  }

  @override
  List<FileTransfer> filesTransfers(int id) => List.of(transfers);
  @override
  void filesClearTransfers(int id) => transfers.removeWhere((t) => t.finished);

  /// Forward statuses reported for live sessions, and every toggle asked for.
  List<SshForwardStatus> forwards = [];
  final List<String> forwardCalls = [];

  @override
  List<SshForwardStatus> sshForwards(int sessionId) => forwards;

  @override
  Future<int> sshForwardSet(int sessionId, int index, bool enabled) async {
    forwardCalls.add('$sessionId $index $enabled');
    forwards = [
      for (final f in forwards)
        f.index == index
            ? SshForwardStatus(
                index: f.index,
                forward: f.forward,
                active: enabled,
                boundPort: enabled ? f.forward.bindPort : 0,
                error: null,
              )
            : f,
    ];
    return 0;
  }

  @override
  List<StoreRecord> recordsList(String collection) => [
    for (final e in (records[collection] ?? {}).entries) StoreRecord(id: e.key, json: e.value),
  ];
  @override
  StoreRecord? recordGet(String collection, String id) {
    final json = records[collection]?[id];
    return json == null ? null : StoreRecord(id: id, json: json);
  }

  @override
  void recordPut(String collection, String id, String json) => (records[collection] ??= {})[id] = json;
  @override
  bool recordDelete(String collection, String id) => (records[collection] ?? {}).remove(id) != null;
  @override
  String? settingGet(String key) => settings[key];
  @override
  void settingSet(String key, String json) => settings[key] = json;
  @override
  void secretPut(String id, String kind, String value) => secrets[id] = value;
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
  KeyInfo keyInspect(String privateKey, String? passphrase) {
    // A PuTTY key comes back converted, as the engine does it.
    final putty = privateKey.trimLeft().startsWith('PuTTY-User-Key-File-');
    return KeyInfo(
      kind: 'ed25519',
      publicOpenssh: 'ssh-ed25519 AAAAimported',
      fingerprint: 'SHA256:imported',
      encrypted: false,
      comment: '',
      privateOpenssh: putty
          ? '-----BEGIN OPENSSH PRIVATE KEY-----\nconverted\n-----END OPENSSH PRIVATE KEY-----\n'
          : null,
      converted: putty,
    );
  }

  @override
  String keyFingerprint(String publicKey) => 'SHA256:${publicKode(publicKey)}';
  static int publicKode(String s) => s.hashCode;

  // ---- Import ----
  List<SshConfigHost> configHosts = const [];
  List<String>? imported;

  /// Imported themes, listed after the built-in ones.
  final List<ThemeInfo> customThemes = [];

  @override
  List<CsvHost> csvHostsPreview(String text) {
    final lines = text.trim().split('\n');
    if (lines.length < 2 || !lines.first.toLowerCase().contains('host')) throw 'the first line must name the columns';
    return [
      for (final line in lines.skip(1))
        CsvHost(
          label: line.split(',')[0],
          hostname: line.split(',')[1],
          port: 22,
          username: line.split(',').length > 2 ? line.split(',')[2] : '',
          hasPassword: line.split(',').length > 3 && line.split(',')[3].isNotEmpty,
          group: null,
          tags: const [],
          alreadyImported: (records['hosts'] ?? {}).values.any((j) => j.contains('"label":"${line.split(',')[0]}"')),
        ),
    ];
  }

  @override
  ImportReport csvHostsImport(String text, List<int> rows) {
    final hosts = csvHostsPreview(text);
    var n = 0;
    for (final i in rows) {
      final h = hosts[i];
      final id = 'csv-$i';
      records.putIfAbsent('hosts', () => {})[id] = hostJson(id, h.label);
      n++;
    }
    return ImportReport(hosts: n, keys: 0, skipped: const []);
  }

  @override
  List<ThemeInfo> themeImportPreview(String text, String filename) {
    if (!text.contains('base00') && !text.contains('<plist')) throw 'not a theme file Promptly knows';
    final name = filename.split('.').first;
    return [
      ThemeInfo(
        id: '',
        name: name[0].toUpperCase() + name.substring(1),
        dark: true,
        foreground: 0xD8D8D8,
        background: 0x181818,
        cursor: 0xD8D8D8,
        selection: 0x383838,
        ansi: Uint32List.fromList(List.generate(16, (i) => 0x101010 * (i + 1))),
        builtin: false,
      ),
    ];
  }

  @override
  ThemeInfo themeSave(ThemeInfo theme) {
    final saved = ThemeInfo(
      id: 'custom-${customThemes.length + 1}',
      name: theme.name,
      dark: theme.dark,
      foreground: theme.foreground,
      background: theme.background,
      cursor: theme.cursor,
      selection: theme.selection,
      ansi: theme.ansi,
      builtin: false,
    );
    customThemes.add(saved);
    return saved;
  }

  @override
  void themeDelete(String id) => customThemes.removeWhere((t) => t.id == id);

  @override
  List<SshConfigHost> sshConfigHosts() => configHosts;
  @override
  ImportReport sshConfigImport(List<String> aliases) {
    imported = aliases;
    for (final a in aliases) {
      records.putIfAbsent('hosts', () => {})['imported-$a'] = hostJson('imported-$a', a);
    }
    return ImportReport(hosts: aliases.length, keys: 1, skipped: const []);
  }

  // ---- Sync ----
  static const notConfigured = SyncStatus(
    configured: false,
    kind: null,
    location: null,
    vaultId: null,
    deviceId: 'this-device',
    deviceName: '',
    syncing: false,
    lastSyncAt: null,
    lastError: null,
    warnings: [],
    pendingOps: 0,
    devices: [],
    vaultBytes: 0,
    recoveryHint: null,
    changes: 0,
  );
  SyncStatus sync = notConfigured;
  final StreamController<SyncStatus> syncStream = StreamController<SyncStatus>.broadcast();
  final List<String> syncCalls = [];

  /// Folders that already hold a vault, for the join path.
  final Set<String> foldersWithVaults = {};

  void _configured(String path, String name) {
    sync = SyncStatus(
      configured: true,
      kind: SyncBackendKind.localFolder,
      location: path,
      vaultId: 'vault-1',
      deviceId: 'this-device',
      deviceName: name,
      syncing: false,
      lastSyncAt: DateTime.now().toUtc().toIso8601String(),
      lastError: null,
      warnings: const [],
      pendingOps: 0,
      devices: [
        SyncDevice(
          id: 'this-device',
          name: name,
          platform: 'linux',
          enrolledAt: '2026-10-15T06:00:00Z',
          lastSeenAt: null,
          isThisDevice: true,
        ),
        const SyncDevice(
          id: 'other',
          name: 'Phone',
          platform: 'android',
          enrolledAt: '2026-10-15T06:00:00Z',
          lastSeenAt: null,
          isThisDevice: false,
        ),
      ],
      vaultBytes: 2048,
      recoveryHint: 'R7Q2',
      changes: 0,
    );
    syncStream.add(sync);
  }

  @override
  SyncStatus syncStatus() => sync;
  @override
  Stream<SyncStatus> syncEvents() => syncStream.stream;
  @override
  bool syncFolderHasVault(String path) => foldersWithVaults.contains(path);
  @override
  String syncDefaultDeviceName() => 'test-box (Linux)';
  @override
  Future<SyncSetupResult> syncCreateLocalFolder(String path, String passphrase, String deviceName) async {
    syncCalls.add('create $path $deviceName');
    _configured(path, deviceName);
    return const SyncSetupResult(vaultId: 'vault-1', recoveryCode: 'R7Q2-K9XM-3TPA-8VBD-2NCF-7HJQ-5WZ1-6GYE');
  }

  @override
  Future<void> syncJoinLocalFolder(
    String path, {
    String? passphrase,
    String? recoveryCode,
    required String deviceName,
  }) async {
    syncCalls.add('join $path pass=$passphrase code=$recoveryCode');
    if (passphrase == 'wrong') throw 'the passphrase is wrong';
    _configured(path, deviceName);
  }

  @override
  Future<bool> syncSftpFolderHasVault(String hostId, String remoteDir) async {
    syncCalls.add('probe-sftp $hostId $remoteDir');
    return foldersWithVaults.contains('$hostId:$remoteDir');
  }

  @override
  Future<SyncSetupResult> syncCreateSftp(String hostId, String remoteDir, String passphrase, String deviceName) async {
    syncCalls.add('create-sftp $hostId $remoteDir $deviceName');
    _configured('test server · $remoteDir', deviceName);
    return const SyncSetupResult(vaultId: 'vault-2', recoveryCode: 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH');
  }

  @override
  Future<void> syncJoinSftp(
    String hostId,
    String remoteDir, {
    String? passphrase,
    String? recoveryCode,
    required String deviceName,
  }) async {
    syncCalls.add('join-sftp $hostId $remoteDir pass=$passphrase');
    _configured('test server · $remoteDir', deviceName);
  }

  @override
  Future<SyncStatus> syncNow() async {
    syncCalls.add('sync-now');
    return sync;
  }

  @override
  void syncDisconnect() {
    syncCalls.add('disconnect');
    sync = notConfigured;
    syncStream.add(sync);
  }

  @override
  Future<void> syncRemoveDevice(String deviceRecordId) async => syncCalls.add('remove $deviceRecordId');
  @override
  String? syncQrPayload() => sync.configured ? '{"v":1}' : null;
}

/// Scroll a lazily built list until a widget shows, then tap it.
Future<void> scrollTap(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 150, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

/// Scroll a lazily built list until a widget shows.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 150, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

/// Scroll to a widget inside a scrollable page, then tap it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Widget app([FakeEngine? engine]) => appWith(engine);

/// The app on a fake engine. The welcome tour counts as seen unless a test
/// asks for a first run.
Widget appWith(FakeEngine? engine, {String? localDir, Fs? localFs, bool onboarded = true, PickedTextFile? pickedFile}) {
  engine ??= FakeEngine();
  if (onboarded) engine.settings.putIfAbsent('onboarding_done', () => 'true');
  return ProviderScope(
    overrides: [
      engineProvider.overrideWithValue(engine),
      filePickerProvider.overrideWithValue(
        ({required String label, required List<String> extensions}) async => pickedFile,
      ),
      if (localDir != null) localStartDirProvider.overrideWithValue(localDir),
      if (localFs != null) localFsProvider.overrideWithValue(localFs),
    ],
    child: const PromptlyApp(),
  );
}

String hostJson(
  String id,
  String label, {
  String? group,
  String? color,
  String auth = '{"kind":"interactive"}',
  String? lastConnected,
  bool favourite = false,
}) =>
    '{"id":"$id","label":"$label","hostname":"$label.example","port":22,"username":"ops",'
    '"auth":$auth,"group_id":${group == null ? 'null' : '"$group"'},"tags":[],'
    '"color":${color == null ? 'null' : '"$color"'},'
    '"icon":null,"notes":"","jump_host_id":null,"keepalive_seconds":30,"startup_command":null,"env":{},'
    '"persistent_session":false,"port_forwards":[],'
    '"last_connected_at":${lastConnected == null ? 'null' : '"$lastConnected"'},"favourite":$favourite,"sync":"vault"}';

/// A folder tree in memory, standing in for this device's disk.
class MemoryFs extends Fs {
  MemoryFs(this.tree);

  final Map<String, List<FsEntry>> tree;
  final List<String> calls = [];

  @override
  String get label => 'This device';
  @override
  bool get isRemote => false;
  @override
  Future<String> home() async => tree.keys.first;
  final Map<String, String> text = {};

  @override
  Future<String> readText(String path) async => text[path] ?? (throw 'not a text file');

  @override
  Future<void> writeText(String path, String body) async {
    calls.add('write $path');
    text[path] = body;
  }

  @override
  Future<List<FsEntry>> list(String dir) async => tree[dir] ?? (throw 'no such folder');
  @override
  Future<void> mkdir(String path) async => calls.add('mkdir $path');
  @override
  Future<void> rename(String from, String to) async => calls.add('rename $from $to');
  @override
  Future<void> delete(String path) async => calls.add('delete $path');
  @override
  Future<void> chmod(String path, int mode) async => calls.add('chmod $path');
}

/// A desktop-sized window, so the Sessions tab shows the workspace and the
/// menu bar appears. Reset after the test.
void desktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = true,
  bool shift = true,
  bool alt = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

WorkspaceState workspaceOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(WorkspaceScreen))).read(workspaceProvider);

String snippetJson(String id, String label, String command, {String variables = '[]'}) =>
    '{"id":"$id","label":"$label","command":"$command","tags":[],"variables":$variables}';

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
    await scrollTo(tester, find.text('Rust engine 9.9.9-test'));
    expect(find.text('Rust engine 9.9.9-test'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ping-input')), 'Ada');
    await scrollTap(tester, find.text('Ping'));
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
    engine.records['groups'] = {'g1': '{"id":"g1","label":"Production","parent_id":null,"color":null,"defaults":{}}'};
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1', group: 'g1'), 'h2': hostJson('h2', 'nas')};
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

  testWidgets('the sessions list shows a live thumbnail and a summary', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 1;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local shell'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to sessions'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionThumbnail), findsOneWidget);
    expect(find.text('1 live'), findsOneWidget);
    expect(find.text('Local shell · 142×37'), findsOneWidget);
  });

  testWidgets("a saved host's colour runs along the top of its session", (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'prod-db', color: 'red')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-colour-bar')), findsOneWidget);
    expect(find.text('deploy@web-1: ~'), findsOneWidget, reason: 'the session is live');
  });

  testWidgets('a dropped SSH connection reconnects by itself, keeping the session', (tester) async {
    final engine = FakeEngine()
      ..connectedSessionId = 7
      ..dropAfterFrame = true;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'deploy@web-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(engine.requests.length, 1);
    expect(find.text('Connection dropped'), findsOneWidget);
    expect(find.textContaining('try 1'), findsOneWidget);
    expect(engine.notices.single, contains('Connection dropped'));

    // The first try comes after a second, and asks for the same session back.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(engine.requests.length, 2);
    expect(engine.requests.last.reattachSessionId, 7);
    expect(engine.requests.last.cols, 142, reason: 'the new connection gets the live size');
    await tester.pumpAndSettle();
    expect(find.text('Connection dropped'), findsNothing, reason: 'reconnected');
    expect(find.text('deploy@web-1: ~'), findsOneWidget, reason: 'same session, same title');
  });

  testWidgets('Stop ends the reconnect attempts and leaves the session on screen', (tester) async {
    final engine = FakeEngine()
      ..connectedSessionId = 7
      ..dropAfterFrame = true;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'deploy@web-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(find.text('Connection dropped'), findsNothing);
    expect(find.text('The connection ended.'), findsOneWidget);
    expect(engine.requests.length, 1, reason: 'no further tries');
    // Reconnect from the ended overlay goes straight for the same session.
    await tester.tap(find.text('Reconnect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(engine.requests.length, 2);
    expect(engine.requests.last.reattachSessionId, 7);
  });

  testWidgets('setting up a vault in a folder shows the recovery code, then the sync status', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Vault not set up'));
    expect(find.text('Vault not set up'), findsOneWidget);
    await scrollTap(tester, find.text('Set up'));
    await tester.pumpAndSettle();
    expect(find.text('Where should Promptly keep your vault?'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('sync-continue')));
    await tester.pumpAndSettle();
    expect(find.text('test-box (Linux)'), findsOneWidget, reason: 'the device name is suggested');
    await tester.enterText(find.byKey(const Key('sync-path')), '/tmp/vault');
    await tapVisible(tester, find.byKey(const Key('sync-folder-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a passphrase'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-passphrase')), 'short');
    await tester.enterText(find.byKey(const Key('sync-passphrase-confirm')), 'short');
    await tapVisible(tester, find.byKey(const Key('sync-create')));
    await tester.pumpAndSettle();
    expect(find.textContaining('at least eight'), findsOneWidget);
    expect(engine.syncCalls, isEmpty);
    await tester.enterText(find.byKey(const Key('sync-passphrase')), 'correct horse battery');
    await tester.enterText(find.byKey(const Key('sync-passphrase-confirm')), 'correct horse battery');
    await tapVisible(tester, find.byKey(const Key('sync-create')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['create /tmp/vault test-box (Linux)']);
    expect(find.text('R7Q2-K9XM-3TPA-8VBD-2NCF-7HJQ-5WZ1-6GYE'), findsOneWidget);
    final done = tester.widget<FilledButton>(find.byKey(const Key('sync-done')));
    expect(done.onPressed, isNull, reason: 'Done waits for the checkbox');
    await tapVisible(tester, find.byKey(const Key('sync-wrote-it-down')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('sync-done')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.textContaining('Synced just now · 2 devices'));
    expect(find.textContaining('Synced just now · 2 devices'), findsOneWidget);
    await scrollTap(tester, find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsOneWidget);
    expect(find.byTooltip('Remove device'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('sync-now')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls.last, 'sync-now');
  });

  testWidgets('a folder that already holds a vault asks for the passphrase and reports a wrong one', (tester) async {
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
    expect(find.text('This folder already holds a vault'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-join-passphrase')), 'wrong');
    await tapVisible(tester, find.byKey(const Key('sync-join')));
    await tester.pumpAndSettle();
    expect(find.text('the passphrase is wrong'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-join-passphrase')), 'right');
    await tapVisible(tester, find.byKey(const Key('sync-join')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls.last, 'join /shared/vault pass=right code=null');
    expect(find.byKey(const Key('sync-summary')), findsOneWidget, reason: 'joined: the status view is up');
  });

  testWidgets('a vault on a saved host goes through the server step', (tester) async {
    final engine = FakeEngine();
    engine.records['hosts'] = {
      'h1': hostJson(
        'h1',
        'web-1',
        auth: '{"kind":"password","password_secret_id":"0192f3a0-0000-7000-8000-000000000002"}',
      ),
      'h2': hostJson('h2', 'nas'), // no stored login: must not be offered
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.text('Set up'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-option-sftp')));
    await tapVisible(tester, find.byKey(const Key('sync-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Which server?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sync-host')));
    await tester.pumpAndSettle();
    expect(find.textContaining('nas'), findsNothing, reason: 'hosts without a stored login are left out');
    await tester.tap(find.textContaining('web-1').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-remote')), 'vaults/promptly');
    await tapVisible(tester, find.byKey(const Key('sync-server-continue')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['probe-sftp h1 vaults/promptly']);
    expect(find.text('Choose a passphrase'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-passphrase')), 'correct horse battery');
    await tester.enterText(find.byKey(const Key('sync-passphrase-confirm')), 'correct horse battery');
    await tapVisible(tester, find.byKey(const Key('sync-create')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls.last, 'create-sftp h1 vaults/promptly test-box (Linux)');
    expect(find.text('AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH'), findsOneWidget);
  });

  testWidgets('hosts from ~/.ssh/config can be picked and imported', (tester) async {
    final engine = FakeEngine()
      ..configHosts = const [
        SshConfigHost(
          alias: 'web-1',
          hostname: 'web-1.example',
          user: 'deploy',
          port: 22,
          identityFile: '/home/me/.ssh/id_ed25519',
          keyReadable: true,
          proxyJump: null,
          alreadyImported: false,
        ),
        SshConfigHost(
          alias: 'db',
          hostname: '10.0.0.20',
          user: 'postgres',
          port: 2222,
          identityFile: null,
          keyReadable: false,
          proxyJump: 'web-1',
          alreadyImported: false,
        ),
        SshConfigHost(
          alias: 'old',
          hostname: 'old.example',
          user: '',
          port: 22,
          identityFile: null,
          keyReadable: false,
          proxyJump: null,
          alreadyImported: true,
        ),
      ];
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('import-ssh-config')));
    await tester.tap(find.descendant(of: find.byKey(const Key('import-ssh-config')), matching: find.text('Import')));
    await tester.pumpAndSettle();
    expect(find.text('Import from ~/.ssh/config'), findsWidgets);
    expect(find.text('already saved'), findsOneWidget);
    expect(find.text('Import 2'), findsOneWidget, reason: 'the two new hosts are ticked');
    await tester.tap(find.byKey(const Key('import-db')));
    await tester.pumpAndSettle();
    expect(find.text('Import 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-go')));
    await tester.pumpAndSettle();
    expect(engine.imported, ['web-1']);
    expect(find.textContaining('Imported 1 host and 1 key'), findsOneWidget);
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    expect(find.text('web-1'), findsOneWidget, reason: 'the list reloaded');
  });

  testWidgets('programs may write the clipboard only when the setting is on', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(engine.settings['program_clipboard'], isNull);
    await scrollTap(tester, find.byKey(const Key('program-clipboard')));
    await tester.pumpAndSettle();
    expect(engine.settings['program_clipboard'], 'true');
  });

  testWidgets("a group's defaults fill in a host's blank user and key", (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['groups'] = {
      'g1': '{"id":"g1","label":"Production","parent_id":null,"color":null,"defaults":{"username":"ops-default","identity_id":"k1"}}',
    };
    engine.records['identities'] = {
      'k1': '{"id":"k1","label":"laptop","key_type":"ed25519","public_key":"ssh-ed25519 AAAA","private_key_secret_id":"s1"}',
    };
    engine.secrets['s1'] = '-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----';
    engine.records['hosts'] = {
      'h1': hostJson('h1', 'web-1', group: 'g1').replaceFirst('"username":"ops"', '"username":""'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    final request = engine.requests.single;
    expect(request.user, 'ops-default');
    expect(request.auth, SshAuthKind.key);
    expect(request.privateKey, contains('PRIVATE KEY'));
  });

  testWidgets('the host editor saves a jump host, tmux persistence and a port forward', (tester) async {
    final engine = FakeEngine();
    engine.records['hosts'] = {'b1': hostJson('b1', 'bastion'), 'a1': hostJson('a1', 'app-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Host actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit host'), findsOneWidget);

    await scrollTap(tester, find.byKey(const Key('host-jump')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bastion').last);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('host-persistent')));
    await scrollTap(tester, find.byKey(const Key('forward-add')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('forward-auto-0')));
    await tester.enterText(find.byKey(const Key('forward-port-0')), '8080');
    await tester.enterText(find.byKey(const Key('forward-target-host-0')), 'db');
    await tester.enterText(find.byKey(const Key('forward-target-port-0')), '5432');
    await tester.tap(find.byKey(const Key('host-save')));
    await tester.pumpAndSettle();

    final saved = engine.records['hosts']!['a1']!;
    expect(saved, contains('"jump_host_id":"b1"'));
    expect(saved, contains('"persistent_session":true'));
    expect(saved, contains('"agent_forwarding":false'));
    expect(
      saved,
      contains('"kind":"local","bind_host":"","bind_port":8080,"target_host":"db","target_port":5432,"auto":true'),
    );
  });

  testWidgets('connecting through a jump host sends the chain, tmux and the forwards, which the session can toggle', (
    tester,
  ) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.secrets['p1'] = 'hunter2';
    engine.records['hosts'] = {
      'b1': hostJson('b1', 'bastion', auth: '{"kind":"password","password_secret_id":"p1"}'),
      'a1': hostJson('a1', 'app-1')
          .replaceFirst('"jump_host_id":null', '"jump_host_id":"b1"')
          .replaceFirst('"persistent_session":false', '"persistent_session":true')
          .replaceFirst(
            '"port_forwards":[]',
            '"port_forwards":[{"kind":"local","bind_host":"","bind_port":8080,"target_host":"db","target_port":5432,"auto":true}]',
          ),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-a1')));
    await tester.pumpAndSettle();
    final r = engine.requests.single;
    expect(r.host, 'app-1.example');
    expect(r.jumps.single.host, 'bastion.example');
    expect(r.jumps.single.auth, SshAuthKind.password);
    expect(r.jumps.single.password, 'hunter2', reason: 'the jump host logs in with its own stored password');
    expect(r.persistent, isTrue);
    expect(r.forwards.single.bindPort, 8080);

    engine.forwards = [
      SshForwardStatus(index: 0, forward: r.forwards.single, active: true, boundPort: 8080, error: null),
    ];
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-forwards')));
    await tester.pumpAndSettle();
    expect(find.text('8080 → db:5432'), findsOneWidget);
    expect(find.text('Listening on port 8080 here'), findsOneWidget);
    await tester.tap(find.byKey(const Key('forward-switch-0')));
    await tester.pumpAndSettle();
    expect(engine.forwardCalls, ['7 0 false']);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('jump hosts that go round in a circle are refused with a plain message', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {
      'b1': hostJson('b1', 'bastion').replaceFirst('"jump_host_id":null', '"jump_host_id":"a1"'),
      'a1': hostJson('a1', 'app-1').replaceFirst('"jump_host_id":null', '"jump_host_id":"b1"'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-a1')));
    await tester.pumpAndSettle();
    expect(engine.requests, isEmpty);
    expect(find.textContaining('go round in a circle'), findsOneWidget);
  });

  testWidgets('a snippet is saved with the variables found in its command', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Snippets').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add snippet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('snippet-label')), 'Disk');
    await tester.enterText(find.byKey(const Key('snippet-command')), 'df -h {{path}}');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('var-default-path')), findsOneWidget, reason: 'the variable is picked up as typed');
    await tester.enterText(find.byKey(const Key('var-default-path')), '/');
    await tester.tap(find.byKey(const Key('snippet-save')));
    await tester.pumpAndSettle();
    expect(
      engine.records['snippets']!.values.single,
      contains('"variables":[{"name":"path","default":"/","prompt":""}]'),
    );
    expect(find.text('Disk'), findsOneWidget);
    expect(find.text('df -h {{path}}'), findsOneWidget);
  });

  testWidgets('a snippet run from a live session asks for its variables and types the command', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['snippets'] = {
      's1': snippetJson(
        's1',
        'Disk',
        'df -h {{path}}',
        variables: '[{"name":"path","default":"/","prompt":"Which folder?"}]',
      ),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'deploy@web-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-snippets')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-snippet-s1')));
    await tester.pumpAndSettle();
    expect(find.text('Which folder?'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('var-path')), '/srv');
    await tester.tap(find.byKey(const Key('snippet-run-go')));
    await tester.pumpAndSettle();
    expect(engine.pasted, ['df -h /srv']);
    expect(engine.written.last, [13], reason: 'Enter runs it');
  });

  testWidgets('a snippet run on several hosts shows what each one printed', (tester) async {
    final engine = FakeEngine();
    engine.secrets['p1'] = 'hunter2';
    engine.records['hosts'] = {
      'h1': hostJson('h1', 'web-1', auth: '{"kind":"password","password_secret_id":"p1"}'),
      'h2': hostJson('h2', 'web-2', auth: '{"kind":"password","password_secret_id":"p1"}'),
    };
    engine.records['snippets'] = {'s1': snippetJson('s1', 'Uptime', 'uptime')};
    engine.execResults['web-1.example'] = const SshExecResult(
      output: ' up 3 days',
      exitCode: 0,
      timedOut: false,
      error: null,
    );
    engine.execResults['web-2.example'] = const SshExecResult(
      output: '',
      exitCode: null,
      timedOut: false,
      error: 'Connect to web-2 in the terminal once first, so its host key is trusted.',
    );
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
    expect(find.text('Run on 2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('run-on-hosts-go')));
    await tester.pumpAndSettle();
    expect(engine.execCalls, ['web-1.example uptime', 'web-2.example uptime']);
    expect(find.textContaining('up 3 days'), findsOneWidget);
    expect(find.text('Exit 0'), findsOneWidget);
    expect(find.textContaining('host key is trusted'), findsOneWidget);
  });

  testWidgets('Ctrl+Shift+F opens the search bar, which counts matches and closes with Escape', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'deploy@web-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('search-field')), 'needle');
    await tester.pumpAndSettle();
    expect(engine.searchCalls, ['search needle', 'step back']);
    expect(find.text('2 of 5'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-next')));
    await tester.pumpAndSettle();
    expect(engine.searchCalls.last, 'step forward');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-field')), findsNothing);
    expect(engine.searchCalls.last, 'search null', reason: 'closing drops the highlights');
  });

  testWidgets('on a desktop window sessions open in tabs and panes, and an empty pane connects a host', (tester) async {
    desktopWindow(tester);
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1'), 'h2': hostJson('h2', 'web-2')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.text('File'), findsOneWidget, reason: 'the menu bar is there on desktop');
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceScreen), findsOneWidget);
    expect(find.byType(SessionBody), findsOneWidget);
    expect(find.byTooltip('Close tab'), findsOneWidget);
    expect(find.text('deploy@web-1: ~'), findsWidgets, reason: 'the pane and the tab both show the title');

    await chord(tester, LogicalKeyboardKey.keyD);
    expect(find.text('Drop a host here'), findsOneWidget, reason: 'Ctrl+Shift+D splits off an empty pane');
    expect(workspaceOf(tester).currentTab!.leaves.length, 2);
    await tester.tap(find.byKey(const Key('pane-host-h2')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(engine.requests.length, 2);
    expect(find.byType(SessionBody), findsNWidgets(2));
    expect(find.text('Drop a host here'), findsNothing);

    await chord(tester, LogicalKeyboardKey.keyW);
    expect(find.byType(SessionBody), findsOneWidget, reason: 'Ctrl+Shift+W closes the focused pane');
    expect(workspaceOf(tester).currentTab!.leaves.length, 1);
  });

  testWidgets('tabs open, cycle and close with the keyboard', (tester) async {
    desktopWindow(tester);
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close tab'), findsOneWidget);
    await chord(tester, LogicalKeyboardKey.keyT);
    expect(find.byTooltip('Close tab'), findsNWidgets(2));
    expect(workspaceOf(tester).current, 1);
    await chord(tester, LogicalKeyboardKey.tab, shift: false);
    expect(workspaceOf(tester).current, 0, reason: 'Ctrl+Tab wraps round');
    await chord(tester, LogicalKeyboardKey.digit2, control: false, shift: false, alt: true);
    expect(workspaceOf(tester).current, 1, reason: 'Alt+2 picks the second tab');
    await tester.tap(find.byTooltip('Close tab').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close tab'), findsOneWidget);
    expect(find.text('Drop a host here'), findsOneWidget, reason: 'the last tab is never removed, only emptied');
  });

  testWidgets('the command palette connects to a host and switches the terminal theme', (tester) async {
    desktopWindow(tester);
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyP);
    expect(find.byKey(const Key('palette-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('palette-field')), 'web');
    await tester.pumpAndSettle();
    expect(find.text('Connect to web-1'), findsOneWidget);
    expect(find.text('New tab'), findsNothing, reason: 'filtered out');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(engine.requests.length, 1);
    expect(find.byKey(const Key('palette-field')), findsNothing);

    await chord(tester, LogicalKeyboardKey.keyP);
    await tester.enterText(find.byKey(const Key('palette-field')), 'theme drac');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('palette-theme-dracula')));
    await tester.pumpAndSettle();
    expect(engine.settings['terminal_theme'], '"dracula"');
  });

  testWidgets('a host dragged from the hosts panel onto an empty pane connects there', (tester) async {
    desktopWindow(tester);
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyB);
    expect(find.byKey(const Key('panel-host-h1')), findsOneWidget, reason: 'Ctrl+Shift+B shows the hosts panel');
    final from = tester.getCenter(find.byKey(const Key('panel-host-h1')));
    final to = tester.getCenter(find.text('Drop a host here'));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(from + const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(engine.requests.length, 1);
    expect(find.byType(SessionBody), findsOneWidget);
  });

  testWidgets('the file browser lists a host, walks into folders, and makes, renames, chmods and deletes', (
    tester,
  ) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-files')));
    await tester.pumpAndSettle();
    expect(engine.fileCalls, ['open 7'], reason: "the engine's session id, not the app's");
    expect(find.text('Files on web-1'), findsOneWidget);
    expect(find.byKey(const Key('remote-entry-projects')), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget, reason: 'sizes are shown');
    expect(find.byKey(const Key('local-pane')), findsNothing, reason: 'one pane on a narrow window');

    await tester.tap(find.byKey(const Key('remote-entry-projects')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remote-entry-app.py')), findsOneWidget);
    await tester.tap(find.byKey(const Key('remote-up')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remote-entry-notes.txt')), findsOneWidget);

    await tester.tap(find.byKey(const Key('remote-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('files-name')), 'logs');
    await tester.tap(find.byKey(const Key('files-name-ok')));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'mkdir /home/ops/logs');

    await tester.tap(find.byKey(const Key('entry-menu-notes.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('files-name')), 'todo.txt');
    await tester.tap(find.byKey(const Key('files-name-ok')));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'rename /home/ops/notes.txt /home/ops/todo.txt');

    await tester.tap(find.byKey(const Key('entry-menu-notes.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Permissions'));
    await tester.pumpAndSettle();
    expect(find.text('rw-r--r--  644'), findsOneWidget);
    await tester.tap(find.byKey(const Key('perm-others-write')));
    await tester.pumpAndSettle();
    expect(find.text('rw-r--rw-  646'), findsOneWidget);
    await tester.tap(find.byKey(const Key('perm-apply')));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'chmod /home/ops/notes.txt 646');

    await tester.tap(find.byKey(const Key('entry-menu-notes.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('files-delete-ok')));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'delete /home/ops/notes.txt');

    await tester.tap(find.byTooltip('Back to the session'));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'close 3', reason: 'leaving closes the browser');
  });

  testWidgets('on a desktop window the local files sit beside the remote ones and drag across to copy', (tester) async {
    desktopWindow(tester);
    final local = MemoryFs({
      '/home/me': [const FsEntry(name: 'local.txt', path: '/home/me/local.txt', isDir: false, size: 10)],
    });
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    await tester.pumpWidget(appWith(engine, localDir: '/home/me', localFs: local));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-files')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('local-pane')), findsOneWidget);
    expect(find.byKey(const Key('local-entry-local.txt')), findsOneWidget, reason: 'the local pane lists the disk');

    // Remote file dragged onto the local side: a download into the local folder.
    final from = tester.getCenter(find.byKey(const Key('remote-entry-notes.txt')));
    final to = tester.getCenter(find.byKey(const Key('local-entry-local.txt')));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(from + const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'download /home/ops/notes.txt /home/me/notes.txt');
    expect(find.text('Transfers'), findsOneWidget);
    expect(find.text('Done · 2.0 KB'), findsOneWidget);

    // And the menu goes the other way.
    await tester.tap(find.byKey(const Key('entry-menu-local.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload to the server'));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'upload /home/me/local.txt /home/ops/local.txt');
  });

  testWidgets('reachability dots appear once the setting is on', (tester) async {
    final engine = FakeEngine();
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1'), 'h2': hostJson('h2', 'web-2')};
    engine.reach['web-1.example'] = (true, 12);
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-reach-h1')), findsNothing, reason: 'off by default');
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('reachability-check')));
    await tester.pumpAndSettle();
    expect(engine.settings['reachability_check'], 'true');
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-reach-h1')), findsOneWidget);
    expect(find.byTooltip('Up · 12 ms'), findsOneWidget);
    expect(find.byTooltip('Not reachable'), findsOneWidget);
  });

  testWidgets('favourites and recent hosts sit above the full list, and the star toggles', (tester) async {
    final engine = FakeEngine();
    final now = DateTime.now().toUtc();
    engine.records['hosts'] = {
      'h1': hostJson('h1', 'alpha', lastConnected: now.subtract(const Duration(hours: 1)).toIso8601String()),
      'h2': hostJson('h2', 'bravo', lastConnected: now.subtract(const Duration(minutes: 5)).toIso8601String()),
      'h3': hostJson('h3', 'charlie', favourite: true),
      'h4': hostJson('h4', 'delta'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.text('FAVOURITES'), findsOneWidget);
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.byKey(const Key('favourite-row-h3')), findsOneWidget);
    final recentRows = tester
        .widgetList(
          find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('recent-row-'),
          ),
        )
        .toList();
    expect(recentRows.map((w) => (w.key as ValueKey<String>).value).toList(), [
      'recent-row-h2',
      'recent-row-h1',
    ], reason: 'newest first');
    expect(find.byKey(const Key('host-row-h3')), findsOneWidget, reason: 'the full list still has it');

    // The search box has a scroller of its own; aim at the list.
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('host-fav-h4')), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-fav-h4')));
    await tester.pumpAndSettle();
    expect(engine.records['hosts']!['h4'], contains('"favourite":true'));
    await tester.scrollUntilVisible(find.byKey(const Key('favourite-row-h4')), -150, scrollable: list);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('favourite-row-h4')), findsOneWidget, reason: 'it joined the Favourites section');

    await tester.enterText(find.byType(TextField).first, 'alp');
    await tester.pumpAndSettle();
    expect(find.text('RECENT'), findsNothing, reason: 'a search shows just the matches');
    expect(find.byKey(const Key('host-row-h1')), findsOneWidget);
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

  testWidgets('the first run shows the welcome tour and Skip remembers it', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(appWith(engine, onboarded: false));
    await tester.pumpAndSettle();
    expect(find.text('Your terminal, everywhere.'), findsOneWidget);
    expect(find.text('No hosts yet'), findsNothing);
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(find.text('No hosts yet'), findsOneWidget);
    expect(engine.settings['onboarding_done'], 'true');

    // The next start goes straight to hosts.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(appWith(engine, onboarded: false));
    await tester.pumpAndSettle();
    expect(find.text('Your terminal, everywhere.'), findsNothing);
    expect(find.text('No hosts yet'), findsOneWidget);
  });

  testWidgets('the tour walks three pages and its last page starts things', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(appWith(engine, onboarded: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Your data, yours.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Ready when you are.'), findsOneWidget);
    expect(find.byKey(const Key('onboarding-start')), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-add-host')));
    await tester.pumpAndSettle();
    expect(find.text('New host'), findsOneWidget, reason: 'Add a host lands in the editor');
    expect(engine.settings['onboarding_done'], 'true');
  });

  testWidgets('help lists the shortcuts, about shows the version, and the tour can be replayed', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('settings-help')));
    await tester.pumpAndSettle();
    expect(find.text('Help'), findsWidgets);
    await scrollTo(tester, find.text('Ctrl+Shift+P'));
    expect(find.text('Ctrl+Shift+P'), findsOneWidget);
    expect(find.text('Command palette: hosts, snippets, themes, every action'), findsOneWidget);
    await scrollTap(tester, find.byKey(const Key('help-tour')));
    await tester.pumpAndSettle();
    expect(find.text('Your terminal, everywhere.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(find.text('No hosts yet'), findsOneWidget);

    // The Settings tab remembers it was on Help; back goes to the list.
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to settings'));
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('settings-about')));
    await tester.pumpAndSettle();
    expect(find.text('Version 1.0.0 · engine 9.9.9-test'), findsOneWidget);
    await scrollTap(tester, find.byKey(const Key('about-licences')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('every main screen lays out at double text size without overflowing', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final engine = FakeEngine()
      ..records['hosts'] = {
        'h1': hostJson(
          'h1',
          'web-1',
          color: 'blue',
          favourite: true,
          lastConnected: DateTime.now().toUtc().toIso8601String(),
        ),
        'h2': hostJson('h2', 'db-primary'),
      }
      ..records['snippets'] = {'s1': snippetJson('s1', 'Disk space', 'df -h {{path}}')};
    await tester.pumpWidget(appWith(engine, onboarded: false));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('onboarding-start')));
    await tester.pumpAndSettle();
    expect(find.text('web-1'), findsWidgets);
    await tester.tap(find.text('web-1').first);
    await tester.pumpAndSettle();
    for (final tab in ['Sessions', 'Snippets', 'Keys', 'Settings']) {
      await tester.tap(find.text(tab).first);
      await tester.pumpAndSettle();
    }
    await scrollTap(tester, find.byKey(const Key('settings-help')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to settings'));
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('settings-about')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add host'));
    await tester.pumpAndSettle();
    expect(find.text('New host'), findsOneWidget);
    // An overflow anywhere above would have failed the test with a RenderFlex error.
  });

  testWidgets('a phone-sized window at larger text still shows the hosts list and a session', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final engine = FakeEngine()
      ..connectedSessionId = 1
      ..records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.text('web-1'), findsOneWidget);
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open a local shell'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-search')), findsOneWidget);
  });

  testWidgets('the terminal exposes its text to screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    final engine = FakeEngine()..connectedSessionId = 1;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local shell'));
    await tester.pumpAndSettle();
    engine.emitText(1, 'hello from the shell');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('Terminal')), findsWidgets);
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp('Terminal')).first);
    expect(node.value, contains('hello from the shell'));
    handle.dispose();
  });

  testWidgets('reduced motion turns off page transitions and the tour slides', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(appWith(FakeEngine(), onboarded: false));
    await tester.pumpAndSettle();
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      materialApp.theme!.pageTransitionsTheme.builders[TargetPlatform.linux],
      isA<NoMotionPageTransitionsBuilder>(),
    );
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pump();
    expect(find.text('Your data, yours.'), findsOneWidget, reason: 'the page jumps instead of sliding');
  });

  testWidgets('a CSV file imports the hosts picked in the preview', (tester) async {
    final engine = FakeEngine();
    const csv = 'Label,Hostname/IP,Username,Password\nweb-1,10.0.0.1,deploy,s3cret\ndb-1,10.0.0.2,root,\n';
    await tester.pumpWidget(
      appWith(
        engine,
        pickedFile: const PickedTextFile(name: 'termius.csv', text: csv),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('import-csv')));
    await tester.tap(find.descendant(of: find.byKey(const Key('import-csv')), matching: find.text('Import')));
    await tester.pumpAndSettle();
    expect(find.text('Import from termius.csv'), findsOneWidget);
    expect(find.text('deploy@10.0.0.1 · password'), findsOneWidget);
    // Leave db-1 out.
    await tester.tap(find.byKey(const Key('csv-import-1')));
    await tester.pumpAndSettle();
    expect(find.text('Import 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('csv-import-go')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Imported 1 host.'), findsOneWidget);
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('db-1'), findsNothing);
  });

  testWidgets('a theme file imports, becomes the terminal theme, and can be removed', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 1;
    const base16 = 'scheme: "Ocean"\nbase00: "2b303b"\nbase05: "c0c5ce"\n';
    await tester.pumpWidget(
      appWith(
        engine,
        pickedFile: const PickedTextFile(name: 'ocean.yaml', text: base16),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('terminal-theme')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-import')));
    await tester.pumpAndSettle();
    expect(find.text('Import Ocean?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('theme-import-save-0')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('YOUR THEMES'));
    expect(find.text('YOUR THEMES'), findsOneWidget);
    expect(find.byKey(const Key('theme-custom-1')), findsOneWidget);
    expect(engine.settings['terminal_theme'], '"custom-1"', reason: 'a single imported theme is put to use');

    await scrollTap(tester, find.byKey(const Key('theme-delete-custom-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-delete-ok')));
    await tester.pumpAndSettle();
    expect(find.text('YOUR THEMES'), findsNothing);
    expect(engine.settings['terminal_theme'], '"auto"', reason: 'the setting falls back');
  });

  testWidgets('a PuTTY key chosen from a file is stored in OpenSSH form', (tester) async {
    final engine = FakeEngine();
    const ppk = 'PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: work\n';
    await tester.pumpWidget(
      appWith(
        engine,
        pickedFile: const PickedTextFile(name: 'work.ppk', text: ppk),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keys').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('key-pick-file')));
    await tester.pumpAndSettle();
    expect(find.text('work'), findsOneWidget, reason: 'the file name names the key');
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(engine.secrets.values.single, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
    expect(find.text('work'), findsOneWidget);
  });

  testWidgets('a remote text file opens in the editor and saves back in place', (tester) async {
    final engine = FakeEngine()
      ..connectedSessionId = 7
      ..records['hosts'] = {'h1': hostJson('h1', 'web-1')}
      ..remoteFiles['/home/ops'] = [
        FileEntry(
          name: 'notes.txt',
          isDir: false,
          isSymlink: false,
          size: BigInt.from(12),
          modified: BigInt.zero,
          permissions: 0x1A4,
          owner: 'ops',
          group: 'ops',
        ),
      ]
      ..remoteText['/home/ops/notes.txt'] = 'hello\nworld\n';
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-files')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remote-entry-notes.txt')));
    await tester.pumpAndSettle();
    expect(find.text('hello\nworld\n'), findsOneWidget);
    expect(find.text('3 lines · Server'), findsOneWidget);
    final save = find.byKey(const Key('editor-save'));
    expect(tester.widget<FilledButton>(save).enabled, isFalse, reason: 'nothing to save yet');

    await tester.enterText(find.byKey(const Key('editor-text')), 'hello\nthere\n');
    await tester.pumpAndSettle();
    expect(find.text('edited'), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(engine.remoteText['/home/ops/notes.txt'], 'hello\nthere\n');
    expect(find.text('Saved notes.txt'), findsOneWidget);
    expect(find.text('edited'), findsNothing);

    // Closing with unsaved changes asks first.
    await tester.enterText(find.byKey(const Key('editor-text')), 'oops');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-close')));
    await tester.pumpAndSettle();
    expect(find.text('Close notes.txt without saving?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('editor-discard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('editor-text')), findsNothing);
    expect(engine.remoteText['/home/ops/notes.txt'], 'hello\nthere\n', reason: 'the discarded text was not written');
  });

  testWidgets('on a phone the session has a keyboard bar whose keys type into the shell', (tester) async {
    touchPlatformOverride = true;
    addTearDown(() => touchPlatformOverride = null);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final engine = FakeEngine()..connectedSessionId = 1;
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open a local shell'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kb-esc')), findsOneWidget);
    await tester.tap(find.byKey(const Key('kb-esc')));
    expect(engine.written.last, [0x1b]);
    final bar = find.descendant(of: find.byType(KeyboardBar), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const Key('kb-up')), 80, scrollable: bar);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kb-up')));
    expect(engine.written.last, [0x1b, 0x5b, 0x41]);
    await tester.scrollUntilVisible(find.byKey(const Key('kb-ctrl')), -80, scrollable: bar);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kb-ctrl')));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: ' c', selection: TextSelection.collapsed(offset: 2)),
    );
    await tester.pump();
    expect(engine.written.last, [3], reason: 'Ctrl+C through the sticky key');
    await tester.tap(find.byKey(const Key('kb-alt')));
    await tester.scrollUntilVisible(find.byKey(const Key('kb-dash')), 80, scrollable: bar);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kb-dash')));
    expect(engine.written.last, [0x1b, 0x2d], reason: 'Alt prefixes Escape');
    expect(find.byKey(const Key('kb-snippets')), findsOneWidget);
  });
}
