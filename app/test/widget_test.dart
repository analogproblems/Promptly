import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/app.dart';
import 'package:promptly/core/theme/theme.dart';
import 'package:promptly/core/theme/tokens.dart';
import 'package:promptly/core/version.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/file_picker.dart';
import 'package:promptly/core/platform.dart';
import 'package:promptly/features/files/device_files.dart';
import 'package:promptly/features/files/files_screen.dart';
import 'package:promptly/features/files/fs.dart';
import 'package:promptly/features/help/about_screen.dart';
import 'package:promptly/features/settings/settings_screen.dart' show TerminalChoices, TextChoices;
import 'package:promptly/features/terminal/font_files.dart';
import 'package:promptly/features/terminal/terminal_fonts.dart';
import 'package:promptly/features/terminal/keyboard_bar.dart';
import 'package:promptly/features/terminal/terminal_view.dart';
import 'package:promptly/features/sessions/session_body.dart';
import 'package:promptly/features/sessions/session_manager.dart' show SessionManager;
import 'package:promptly/features/sessions/sessions_in_background.dart';
import 'package:promptly/features/sessions/session_thumbnail.dart';
import 'package:promptly/features/sessions/status_dot.dart';
import 'package:promptly/features/workspace/workspace.dart';
import 'package:promptly/features/workspace/workspace_screen.dart';
import 'package:promptly/features/updates/updates.dart';
import 'package:promptly/features/lock/app_lock.dart';
import 'package:promptly/features/sync/sync_screen.dart' show SyncScreen;
import 'package:promptly/features/snippets/repositories.dart' show snippetsProvider;
import 'package:promptly/core/router.dart' show routerProvider;

/// A device with nothing to check who is there with.
class NoChecks implements Authenticator {
  @override
  Future<bool> systemAvailable() async => false;
  @override
  Future<bool> systemCheck(String reason) async => false;
  @override
  Future<String> hashPasscode(String passcode) async => passcode;
  @override
  Future<bool> verifyPasscode(String passcode, String hash) async => passcode == hash;
}

/// A stand-in for the Rust engine so widget tests need no native library.
/// Records and secrets live in maps so the hosts and keys screens work.
class FakeEngine implements Engine {
  final Map<String, Map<String, String>> records = {};

  /// How saved secrets are kept; encrypted, as when the system has a keyring.
  SecretsState secretsKept = SecretsState.encrypted;
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
  SecretsState secretsState() => secretsKept;

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

  /// The scrollback the last session was opened with.
  int? scrollback;
  @override
  void terminalSetScrollback(int lines) => scrollback = lines;

  /// Frames pushed after the first one, by `emitText`.
  final StreamController<TerminalEvent> laterFrames = StreamController<TerminalEvent>.broadcast();

  /// Show `text` on the top row of a session, as a program printing it
  /// would, ringing the bell with it when asked.
  void emitText(int id, String text, {bool bell = false}) {
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
              underline: Uint32List(frameCols),
            ),
          ],
          cursor: TerminalCursor(line: 0, col: text.length, shape: TerminalCursorShape.block),
          displayOffset: 0,
          historyLen: 0,
          defaultFg: 0xE6EDF3,
          defaultBg: 0x0E1116,
          cursorColor: 0x7CE38B,
          title: 'deploy@web-1: ~',
          bell: bell,
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
          underline: Uint32List(frameCols),
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
  bool terminalMouse(
    int id,
    TerminalMouseAction action,
    TerminalMouseButton? button,
    int col,
    int row, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) => false;
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

  /// What the engine reports under any cell.
  String? link;

  /// Whether that link's text shows something other than where it goes.
  bool linkHidden = false;
  @override
  TerminalLink? terminalLinkAt(int id, int col, int line) =>
      link == null ? null : TerminalLink(uri: link!, hidden: linkHidden);
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

  /// When set, an attempt whose key is locked and comes without its
  /// passphrase asks for it first, as the engine does, and connects once
  /// it is answered.
  bool askKeyPassphrase = false;
  final Map<int, StreamController<SshEvent>> _waiting = {};

  /// Every secret typed into a connection, in order.
  final List<String?> answeredSecrets = [];

  @override
  int sshConnectBegin(SshConnectRequest request) {
    requests.add(request);
    return requests.length;
  }

  /// When set, SSH attempts fail with this event after one step.
  SshEvent? failWith;

  /// Attempts cancelled or hung up.
  final List<int> cancelledAttempts = [];

  static SshEvent _connected(int id) => SshEvent(
        kind: SshEventKind.connected,
        step: null,
        hostKey: null,
        secretPrompt: null,
        secretForKey: false,
        kbName: null,
        kbInstructions: null,
        kbPrompts: null,
        sessionId: id,
        error: null,
      );

  /// When set, SSH attempts stop after their first step until [finishHeld].
  bool holdConnects = false;
  final Map<int, StreamController<SshEvent>> _held = {};

  void finishHeld(int attemptId) => _held.remove(attemptId)!
    ..add(_connected(connectedSessionId!))
    ..close();

  @override
  Stream<SshEvent> sshConnectEvents(int attemptId) {
    if (holdConnects) {
      final events = StreamController<SshEvent>();
      _held[attemptId] = events;
      events.add(const SshEvent(kind: SshEventKind.progress, step: SshStep.connecting, secretForKey: false));
      return events.stream;
    }
    if (failWith case final fail?) {
      return Stream.fromIterable([
        const SshEvent(kind: SshEventKind.progress, step: SshStep.connecting, secretForKey: false),
        fail,
      ]);
    }
    final id = connectedSessionId;
    if (id == null) return const Stream.empty();
    const progress = SshEvent(
      kind: SshEventKind.progress,
      step: SshStep.connecting,
      hostKey: null,
      secretPrompt: null,
      secretForKey: false,
      kbName: null,
      kbInstructions: null,
      kbPrompts: null,
      sessionId: null,
      error: null,
    );
    final request = requests[attemptId - 1];
    final locked = (request.privateKey ?? '').contains('LOCKED') && request.passphrase == null;
    if (askKeyPassphrase && locked) {
      final events = StreamController<SshEvent>();
      _waiting[attemptId] = events;
      events
        ..add(progress)
        ..add(const SshEvent(
          kind: SshEventKind.secret,
          step: null,
          hostKey: null,
          secretPrompt: 'Passphrase for the private key',
          secretForKey: true,
          kbName: null,
          kbInstructions: null,
          kbPrompts: null,
          sessionId: null,
          error: null,
        ));
      return events.stream;
    }
    return Stream.fromIterable([progress, _connected(id)]);
  }

  @override
  void sshAnswerHostKey(int attemptId, bool trust) {}
  @override
  void sshAnswerSecret(int attemptId, String? secret) {
    answeredSecrets.add(secret);
    _waiting.remove(attemptId)?.add(_connected(connectedSessionId!));
  }
  @override
  void sshAnswerKeyboardInteractive(int attemptId, List<String>? answers) {}
  @override
  void sshCancel(int attemptId) => cancelledAttempts.add(attemptId);

  /// Canned results for snippets run on hosts, by hostname, and the calls made.
  final Map<String, SshExecResult> execResults = {};
  final List<String> execCalls = [];

  @override
  Future<SshExecResult> sshExec(SshConnectRequest request, String command, int timeoutSeconds) async {
    execCalls.add('${request.host} $command');
    return execResults[request.host] ??
        SshExecResult(output: '', exitCode: null, timedOut: false, error: 'no result for ${request.host}');
  }

  /// Keys installed on hosts: host, how it logged in, and the key.
  final List<String> installCalls = [];

  @override
  Future<String> sshInstallPublicKey(SshConnectRequest request, String publicKey) async {
    installCalls.add('${request.host} ${request.auth.name} ${request.password} $publicKey');
    if (request.host == 'down.example') throw 'down.example did not answer.';
    return 'Installed on ${request.label}. It can log in with this key now.';
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

  /// Copies finish at once unless a test wants to watch one run.
  bool finishTransfers = true;

  /// What a cancelled copy reports, as when its part-copied file stays.
  String? cancelError;
  int _nextTransfer = 1;

  FileTransfer _transfer(String remote, {required bool upload, required int size}) {
    final t = FileTransfer(
      id: _nextTransfer++,
      name: remote.split('/').last,
      upload: upload,
      done: BigInt.from(finishTransfers ? size : 0),
      total: BigInt.from(size),
      finished: finishTransfers,
      cancelled: false,
      error: null,
    );
    transfers.add(t);
    return t;
  }

  @override
  int filesDownload(int id, String remote, String local, {required bool replace}) {
    fileCalls.add('download $remote $local${replace ? ' (replace)' : ''}');
    return _transfer(remote, upload: false, size: 2048).id;
  }

  @override
  int filesUpload(int id, String local, String remote, {required bool replace}) {
    fileCalls.add('upload $local $remote${replace ? ' (replace)' : ''}');
    return _transfer(remote, upload: true, size: 10).id;
  }

  FileTransfer _settled(FileTransfer t, {required bool cancelled}) => FileTransfer(
    id: t.id,
    name: t.name,
    upload: t.upload,
    done: cancelled ? t.done : t.total,
    total: t.total,
    finished: true,
    cancelled: cancelled,
    error: cancelled ? cancelError : null,
  );

  @override
  void filesCancelTransfer(int id, int transfer) {
    fileCalls.add('cancel $transfer');
    final i = transfers.indexWhere((t) => t.id == transfer && !t.finished);
    if (i >= 0) transfers[i] = _settled(transfers[i], cancelled: true);
  }

  /// Let every running copy finish.
  void finishAll() {
    for (var i = 0; i < transfers.length; i++) {
      if (!transfers[i].finished) transfers[i] = _settled(transfers[i], cancelled: false);
    }
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
  void recordPut(String collection, String id, String json) {
    writes.add('record $collection');
    (records[collection] ??= {})[id] = json;
  }

  /// Records and secrets in the order they were saved.
  final List<String> writes = [];
  @override
  bool recordDelete(String collection, String id) => (records[collection] ?? {}).remove(id) != null;
  @override
  String? settingGet(String key) => settings[key];
  @override
  void settingSet(String key, String json) => settings[key] = json;
  @override
  void secretPut(String id, String kind, String value) {
    writes.add('secret');
    secrets[id] = value;
  }
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

  /// The passphrase that opens keys whose text says LOCKED.
  static const lockedPassphrase = 'right horse';

  /// What the export was asked for: the key and both passphrases.
  final List<String> exports = [];

  @override
  String keyExport(String privateKey, {String? passphrase, String? newPassphrase}) {
    exports.add('$privateKey old=$passphrase new=$newPassphrase');
    if (newPassphrase == null) return privateKey;
    if (privateKey.contains('LOCKED') && passphrase != lockedPassphrase) throw 'That passphrase is wrong.';
    return 'RELOCKED with $newPassphrase';
  }

  @override
  KeyInfo keyInspect(String privateKey, String? passphrase) {
    // A key whose text says LOCKED needs lockedPassphrase, as an encrypted
    // OpenSSH key does: its public half shows, and a wrong one is refused.
    final locked = privateKey.contains('LOCKED');
    if (locked && passphrase != null && passphrase != lockedPassphrase) throw 'wrong passphrase';
    // A PuTTY key comes back converted, as the engine does it.
    final putty = privateKey.trimLeft().startsWith('PuTTY-User-Key-File-');
    return KeyInfo(
      kind: 'ed25519',
      publicOpenssh: locked ? 'ssh-ed25519 AAAAlocked' : 'ssh-ed25519 AAAAimported',
      fingerprint: 'SHA256:imported',
      encrypted: locked && passphrase == null,
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

  /// When set, the recreated vault's result waits for this, as a slow
  /// folder would; the vault is back (and its warning gone) before then.
  Completer<void>? recreateDone;
  Completer<void>? removeDone;
  Completer<void>? disconnectDone;

  /// Folders that already hold a vault, for the join path.
  final Set<String> foldersWithVaults = {};

  /// Set up and synced, with this device and a phone.
  void configured() => _configured('/shared/vault', 'test-box (Linux)');

  /// Set up, but stopped on a problem with the vault itself.
  void needsAttention(SyncAttention attention, String message) => _configured(
        '/shared/vault',
        'test-box (Linux)',
        attention: attention,
        lastError: message,
      );

  void _configured(String path, String name, {SyncAttention? attention, String? lastError}) {
    sync = SyncStatus(
      attention: attention,
      configured: true,
      kind: SyncBackendKind.localFolder,
      location: path,
      vaultId: 'vault-1',
      deviceId: 'this-device',
      deviceName: name,
      syncing: false,
      lastSyncAt: DateTime.now().toUtc().toIso8601String(),
      lastError: lastError,
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

  /// Another device's changes arrive: the status's count of them moves on.
  void landChanges() {
    final s = sync;
    sync = SyncStatus(
      attention: s.attention,
      configured: s.configured,
      kind: s.kind,
      location: s.location,
      vaultId: s.vaultId,
      deviceId: s.deviceId,
      deviceName: s.deviceName,
      syncing: s.syncing,
      lastSyncAt: s.lastSyncAt,
      lastError: s.lastError,
      warnings: s.warnings,
      pendingOps: s.pendingOps,
      devices: s.devices,
      vaultBytes: s.vaultBytes,
      recoveryHint: s.recoveryHint,
      changes: s.changes + 1,
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

  /// A rough stand-in for the engine's estimate: the most used password
  /// and anything short are refused, and length makes it stronger.
  @override
  PassphraseCheck syncPassphraseCheck(String passphrase) {
    final n = passphrase.length;
    final level = passphrase == 'password' || n < 8
        ? 0
        : n < 14
        ? 1
        : n < 20
        ? 2
        : 3;
    return PassphraseCheck(
      level: level,
      allowed: level > 0,
      advice: passphrase == 'password'
          ? 'This is one of the passwords people use most.'
          : level == 0
          ? 'This is short enough to be guessed quickly.'
          : 'Advice for level $level.',
    );
  }
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
    String? joinCode,
    required String deviceName,
  }) async {
    syncCalls.add('join $path pass=$passphrase code=$recoveryCode${joinCode == null ? '' : ' join=$joinCode'}');
    if (joinCode != null && joinCode != syncQrText) throw 'That is not a join code.';
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
    String? joinCode,
    required String deviceName,
  }) async {
    syncCalls.add('join-sftp $hostId $remoteDir pass=$passphrase${joinCode == null ? '' : ' join=$joinCode'}');
    _configured('test server · $remoteDir', deviceName);
  }

  @override
  Future<SyncStatus> syncNow() async {
    syncCalls.add('sync-now');
    return sync;
  }

  @override
  void syncWake() => syncCalls.add('wake');

  /// The passphrase the vault takes now; any other is wrong.
  String vaultPassphrase = 'new passphrase';

  @override
  Future<void> syncUnlock({String? passphrase, String? recoveryCode}) async {
    syncCalls.add('unlock pass=$passphrase code=$recoveryCode');
    if (passphrase != vaultPassphrase) throw 'the passphrase is wrong';
    _configured('/shared/vault', 'test-box (Linux)');
  }

  @override
  Future<SyncSetupResult> syncRecreateVault(String passphrase) async {
    syncCalls.add('recreate $passphrase');
    _configured('/shared/vault', 'test-box (Linux)');
    await recreateDone?.future;
    return const SyncSetupResult(vaultId: 'vault-1', recoveryCode: 'NEWC-ODE0-0000-0000-0000-0000-0000-0001');
  }

  @override
  Future<void> syncDisconnect() async {
    syncCalls.add('disconnect');
    await disconnectDone?.future;
    sync = notConfigured;
    syncStream.add(sync);
  }

  @override
  Future<void> syncRemoveDevice(String deviceRecordId) async {
    syncCalls.add('remove $deviceRecordId');
    await removeDone?.future;
  }

  @override
  Future<SyncSetupResult> syncRotateKey(String passphrase) async {
    syncCalls.add('rekey $passphrase');
    return const SyncSetupResult(vaultId: 'vault-1', recoveryCode: 'REKE-YED0-0000-0000-0000-0000-0000-0002');
  }
  /// The join code the vault hands out, and the one a join accepts.
  static const syncQrText = '{"v":1,"vault_id":"vault-1","dek":"secret"}';

  @override
  String? syncQrPayload() => sync.configured ? syncQrText : null;
}

/// The add button on the Hosts tab, then Host: the new host form.
Future<void> addHost(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('hosts-add')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('add-host')));
  await tester.pumpAndSettle();
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

/// GitHub as the update check sees it, without the network.
class FakeUpdateService implements UpdateService {
  FakeUpdateService(this.release);

  Release? release;
  int checks = 0;
  File? ran;

  @override
  Future<Release?> latest() async {
    checks++;
    return release;
  }

  @override
  Future<File> download(ReleaseAsset asset, void Function(double) onProgress) async {
    onProgress(1);
    return File(asset.name);
  }

  @override
  Future<void> runInstaller(File installer) async => ran = installer;
}

Widget app([FakeEngine? engine]) => appWith(engine);

/// Fonts kept in memory: the ones "added" and "installed", and which
/// families were loaded from their files.
class FakeFontLibrary implements FontLibrary {
  FakeFontLibrary({List<String> installedFamilies = const ['Fira Code', 'Ubuntu Mono']})
    : system = [for (final f in installedFamilies) FontFamilyFiles(family: f, paths: ['/fonts/$f.ttf'])];

  final List<FontFamilyFiles> mine = [];
  final List<FontFamilyFiles> system;
  final List<String> loaded = [];

  @override
  Future<List<FontFamilyFiles>> added() async => List.of(mine);
  @override
  Future<List<FontFamilyFiles>> installed() async => system;
  @override
  bool get installedByName => true;
  @override
  Future<String> add(String name, Uint8List bytes) async {
    final face = parseFontBytes(bytes, name);
    if (face == null) throw const FormatException('not a font');
    mine.add(FontFamilyFiles(family: face.family, paths: [name], added: true, monospaced: face.monospaced));
    return face.family;
  }

  @override
  Future<void> remove(FontFamilyFiles font) async => mine.removeWhere((f) => f.family == font.family);
  @override
  Future<bool> load(FontFamilyFiles font) async {
    if (!font.added || loaded.contains(font.family)) return false;
    loaded.add(font.family);
    return true;
  }
}

/// The app on a fake engine. The welcome tour counts as seen unless a test
/// asks for a first run.
Widget appWith(
  FakeEngine? engine, {
  String? localDir,
  Fs? localFs,
  bool onboarded = true,
  PickedTextFile? pickedFile,
  UpdateService? updates,
  Authenticator? authenticator,
  SaveTextFile? fileSaver,
  DeviceFiles? deviceFiles,
  FontLibrary? fonts,
}) {
  engine ??= FakeEngine();
  if (onboarded) engine.settings.putIfAbsent('onboarding_done', () => 'true');
  return ProviderScope(
    overrides: [
      engineProvider.overrideWithValue(engine),
      // Fonts from memory: no data folder, and the system's fonts unread.
      fontLibraryProvider.overrideWithValue(fonts ?? FakeFontLibrary()),
      filePickerProvider.overrideWithValue(
        ({required String label, required List<String> extensions}) async => pickedFile,
      ),
      // No save dialog unless a test brings one: nothing is written to disk.
      fileSaverProvider.overrideWithValue(fileSaver),
      if (localDir != null) localStartDirProvider.overrideWithValue(localDir),
      if (localFs != null) localFsProvider.overrideWithValue(localFs),
      if (updates != null) updateServiceProvider.overrideWithValue(updates),
      // No system check and no passcode unless a test brings one: nothing
      // to ask, so keys and the app open as before.
      authenticatorProvider.overrideWithValue(authenticator ?? NoChecks()),
      if (deviceFiles != null) deviceFilesProvider.overrideWithValue(deviceFiles),
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
  String extra = '',
}) =>
    '{"id":"$id","label":"$label","hostname":"$label.example","port":22,"username":"ops",'
    '"auth":$auth,"group_id":${group == null ? 'null' : '"$group"'},"tags":[],'
    '"color":${color == null ? 'null' : '"$color"'},'
    '"icon":null,"notes":"","jump_host_id":null,"keepalive_seconds":30,"startup_command":null,"env":{},'
    '"persistent_session":false,"port_forwards":[],'
    '"last_connected_at":${lastConnected == null ? 'null' : '"$lastConnected"'},"favourite":$favourite,"sync":"vault"$extra}';

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
    await addHost(tester);
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

  group('phone sessions in the background', () {
    const dropped = TerminalEvent(kind: TerminalEventKind.exited, frame: null, clipboard: null, exitCode: null);

    void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    void away(WidgetTester tester) =>
        lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    void back(WidgetTester tester) =>
        lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);

    Future<FakeEngine> connected(WidgetTester tester) async {
      final engine = FakeEngine()..connectedSessionId = 7;
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'deploy@web-1');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('deploy@web-1: ~'), findsOneWidget);
      return engine;
    }

    testWidgets('a session that dropped while the app was away reconnects as soon as it is back', (tester) async {
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      final engine = await connected(tester);
      away(tester);
      engine.laterFrames.add(dropped);
      await tester.pump();
      // Nothing is drawn while the app is away; the session says so for later.
      expect(engine.notices.single, contains('Connection dropped'));
      expect(engine.requests, hasLength(1), reason: 'the first try waits a second');

      back(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.requests, hasLength(2), reason: 'no waiting once back');
      expect(engine.requests.last.reattachSessionId, 7, reason: 'the same session, or its tmux session');
      await tester.pumpAndSettle();
      expect(find.text('Connection dropped'), findsNothing);
      expect(find.text('deploy@web-1: ~'), findsOneWidget);
    });

    testWidgets('a try already under way on coming back is left to finish', (tester) async {
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      final engine = await connected(tester);
      away(tester);
      engine.holdConnects = true;
      engine.laterFrames.add(dropped);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.requests, hasLength(2), reason: 'the first try started while away');

      back(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.requests, hasLength(2), reason: 'no second try on top of it');
      expect(engine.cancelledAttempts, isEmpty);
      engine.finishHeld(2);
      await tester.pumpAndSettle();
      expect(find.text('Connection dropped'), findsNothing);
      expect(find.text('deploy@web-1: ~'), findsOneWidget);
    });

    testWidgets('one whose tries ran out while away tries again on coming back', (tester) async {
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      final engine = await connected(tester);
      engine.failWith = const SshEvent(kind: SshEventKind.failed, secretForKey: false, error: 'no route to host');
      away(tester);
      engine.laterFrames.add(dropped);
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      expect(engine.requests, hasLength(1 + SessionManager.maxRetries));
      expect(engine.notices.last, contains('Try ${SessionManager.maxRetries} '));

      engine.failWith = null;
      back(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.requests.last.reattachSessionId, 7);
      await tester.pumpAndSettle();
      expect(find.text('deploy@web-1: ~'), findsOneWidget);
      expect(find.text('The connection ended.'), findsNothing, reason: 'live again');
    });

    testWidgets('Stop is respected, and a computer coming to the front waits as before', (tester) async {
      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      var engine = await connected(tester);
      engine.laterFrames.add(dropped);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      away(tester);
      back(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(engine.requests, hasLength(1), reason: 'stopped by hand stays stopped');

      touchPlatformOverride = false;
      await tester.pumpWidget(const SizedBox());
      engine = await connected(tester);
      away(tester);
      engine.laterFrames.add(dropped);
      await tester.pump();
      back(tester);
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.requests, hasLength(1), reason: 'the usual wait before the first try');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 50));
      expect(engine.requests, hasLength(2));
      await tester.pumpAndSettle();
    });

    testWidgets('on Android a service keeps sessions running while any are open', (tester) async {
      androidOverride = true;
      addTearDown(() => androidOverride = null);
      final told = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SessionsInBackground.channel, (call) async {
        if (call.method == 'keepAlive') told.add(call.arguments);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SessionsInBackground.channel, null),
      );
      final engine = FakeEngine()..connectedSessionId = 1;
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      expect(told, isEmpty, reason: 'nothing open, nothing to keep');

      await tester.tap(find.text('Sessions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open a local shell'));
      await tester.pumpAndSettle();
      expect(told, [1]);
      await tester.tap(find.byTooltip('Back to sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local shell').first);
      await tester.pumpAndSettle();
      expect(told, [1, 2]);

      await tester.tap(find.byTooltip('Close session'));
      await tester.pumpAndSettle();
      expect(told, [1, 2, 1]);
      // The last one ending stops the service, though it is still listed.
      engine.laterFrames.add(dropped);
      await tester.pumpAndSettle();
      expect(told, [1, 2, 1, 0]);
    });

    testWidgets('on Android Back on a tab\'s first page puts the app in the background', (tester) async {
      androidOverride = true;
      addTearDown(() => androidOverride = null);
      final told = <String>[];
      final system = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SessionsInBackground.channel, (call) async {
        told.add(call.method);
        return null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        system.add(call.method);
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SessionsInBackground.channel, null);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final engine = FakeEngine();
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(told, ['moveToBack']);
      expect(system, isNot(contains('SystemNavigator.pop')), reason: 'closing the app would end its sessions');

      // A page further in still goes back a page.
      told.clear();
      final router = ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider);
      router.go('/settings/about');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(told, isEmpty);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/settings');
    });

    testWidgets('on Android the service stays up while an SSH session reconnects', (tester) async {
      androidOverride = true;
      touchPlatformOverride = true;
      addTearDown(() {
        androidOverride = null;
        touchPlatformOverride = null;
      });
      final told = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SessionsInBackground.channel, (call) async {
        if (call.method == 'keepAlive') told.add(call.arguments);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SessionsInBackground.channel, null),
      );
      final engine = await connected(tester);
      expect(told, [1]);
      // In case Android would not start it from the background, it is told
      // again on coming back, though the count is the same.
      away(tester);
      back(tester);
      await tester.pump();
      expect(told, [1, 1]);

      engine.laterFrames.add(dropped);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Connection dropped'), findsOneWidget);
      expect(told, [1, 1], reason: 'no stop between the drop and the first try');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('deploy@web-1: ~'), findsOneWidget);
      expect(told, [1, 1]);
    });

    testWidgets('on a phone two fingers switch sessions and pinch the text size', (tester) async {
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
      await tester.tap(find.byTooltip('Back to sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local shell').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-body-2')), findsOneWidget);

      Future<void> twoFingers(Offset a, Offset b, Offset moveA, Offset moveB) async {
        final first = await tester.startGesture(a, pointer: 11);
        final second = await tester.startGesture(b, pointer: 12);
        for (var i = 0; i < 10; i++) {
          await first.moveBy(moveA / 10);
          await second.moveBy(moveB / 10);
        }
        await first.up();
        await second.up();
        await tester.pumpAndSettle();
      }

      final centre = tester.getCenter(find.byType(TerminalView));
      // Swiping right goes back to the session before; there is none before the first.
      await twoFingers(
        centre - const Offset(20, 0),
        centre + const Offset(20, 0),
        const Offset(120, 0),
        const Offset(120, 0),
      );
      expect(find.byKey(const ValueKey('session-body-1')), findsOneWidget);
      await twoFingers(
        centre - const Offset(20, 0),
        centre + const Offset(20, 0),
        const Offset(120, 0),
        const Offset(120, 0),
      );
      expect(find.byKey(const ValueKey('session-body-1')), findsOneWidget);
      await twoFingers(
        centre - const Offset(20, 0),
        centre + const Offset(20, 0),
        const Offset(-120, 0),
        const Offset(-120, 0),
      );
      expect(find.byKey(const ValueKey('session-body-2')), findsOneWidget);

      // Spreading two fingers makes the text bigger, and the size is kept.
      await twoFingers(
        centre - const Offset(40, 0),
        centre + const Offset(40, 0),
        const Offset(-20, 0),
        const Offset(20, 0),
      );
      expect(engine.settings['terminal_font_size'], '21.0');
    });
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
    expect(find.textContaining('guessed quickly'), findsWidgets);
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

  Future<void> openSync(WidgetTester tester) async {
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a passphrase changed on another device is asked for, and a wrong one is reported', (tester) async {
    final engine = FakeEngine()
      ..needsAttention(SyncAttention.passphraseChanged, 'The vault\'s passphrase was changed on another device.');
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.text('Sync paused: type the new passphrase'), findsOneWidget, reason: 'the hosts status line');
    await openSync(tester);
    expect(find.text('The vault passphrase or key changed'), findsOneWidget);
    expect(find.text('The vault\'s passphrase was changed on another device.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-unlock-passphrase')), 'old passphrase');
    await tapVisible(tester, find.byKey(const Key('sync-unlock')));
    await tester.pumpAndSettle();
    expect(find.text('the passphrase is wrong'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sync-unlock-passphrase')), 'new passphrase');
    await tapVisible(tester, find.byKey(const Key('sync-unlock')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls.last, 'unlock pass=new passphrase code=null');
    expect(find.byKey(const Key('sync-attention')), findsNothing, reason: 'syncing again');
    expect(find.textContaining('Synced just now'), findsOneWidget);
  });

  testWidgets('a deleted vault folder can be set up again here, with a new recovery code', (tester) async {
    final engine = FakeEngine()..needsAttention(SyncAttention.vaultMissing, 'The vault folder is gone.');
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);
    expect(find.text('The vault folder is missing'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('sync-recreate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-recreate-passphrase')), 'short');
    await tester.enterText(find.byKey(const Key('sync-recreate-confirm')), 'short');
    await tester.tap(find.byKey(const Key('sync-recreate-confirm-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('guessed quickly'), findsWidgets);
    expect(engine.syncCalls, isEmpty);
    await tester.enterText(find.byKey(const Key('sync-recreate-passphrase')), 'a long passphrase');
    await tester.enterText(find.byKey(const Key('sync-recreate-confirm')), 'a long passphrase');
    await tester.tap(find.byKey(const Key('sync-recreate-confirm-button')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['recreate a long passphrase']);
    expect(find.text('Write this down'), findsOneWidget);
    expect(find.text('NEWC-ODE0-0000-0000-0000-0000-0000-0001'), findsOneWidget);
  });

  testWidgets('the new recovery code still shows when it comes after the warning has gone', (tester) async {
    final engine = FakeEngine()
      ..needsAttention(SyncAttention.vaultMissing, 'The vault folder is gone.')
      ..recreateDone = Completer<void>();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);
    await tapVisible(tester, find.byKey(const Key('sync-recreate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-recreate-passphrase')), 'a long passphrase');
    await tester.enterText(find.byKey(const Key('sync-recreate-confirm')), 'a long passphrase');
    await tester.tap(find.byKey(const Key('sync-recreate-confirm-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-attention')), findsNothing, reason: 'the vault is back before the code arrives');

    // Leave the sync screen, then the result comes.
    Navigator.of(tester.element(find.byType(SyncScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsNothing);
    engine.recreateDone!.complete();
    await tester.pumpAndSettle();
    await scrollTap(tester, find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Write this down'), findsOneWidget);
    expect(find.text('NEWC-ODE0-0000-0000-0000-0000-0000-0001'), findsOneWidget);
  });

  testWidgets('removing a device asks whether to re-key too, and re-keying shows the new recovery code', (tester) async {
    final engine = FakeEngine()..configured();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);

    // Remove on its own.
    await tapVisible(tester, find.byTooltip('Remove device'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Phone?'), findsOneWidget);
    expect(find.textContaining('lost or stolen'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sync-remove-confirm')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['remove other']);

    // Remove and re-key, changing your mind at the passphrase: nothing happens.
    await tapVisible(tester, find.byTooltip('Remove device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-remove-rekey')));
    await tester.pumpAndSettle();
    expect(find.text('Re-key the vault'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['remove other']);

    // And through to the end.
    await tapVisible(tester, find.byTooltip('Remove device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-remove-rekey')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-rekey-passphrase')), 'short');
    await tester.enterText(find.byKey(const Key('sync-rekey-confirm')), 'short');
    await tester.tap(find.byKey(const Key('sync-rekey-confirm-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('guessed quickly'), findsWidgets);
    await tester.enterText(find.byKey(const Key('sync-rekey-passphrase')), 'a brand new passphrase');
    await tester.enterText(find.byKey(const Key('sync-rekey-confirm')), 'a brand new passphrase');
    await tester.tap(find.byKey(const Key('sync-rekey-confirm-button')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['remove other', 'remove other', 'rekey a brand new passphrase']);
    expect(find.text('Write this down'), findsOneWidget);
    expect(find.text('REKE-YED0-0000-0000-0000-0000-0000-0002'), findsOneWidget);
  });

  testWidgets('a re-key asked for still happens, and its code shows, after leaving the sync screen', (tester) async {
    final engine = FakeEngine()
      ..configured()
      ..removeDone = Completer<void>();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);
    await tapVisible(tester, find.byTooltip('Remove device'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-remove-rekey')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-rekey-passphrase')), 'a brand new passphrase');
    await tester.enterText(find.byKey(const Key('sync-rekey-confirm')), 'a brand new passphrase');
    await tester.tap(find.byKey(const Key('sync-rekey-confirm-button')));
    await tester.pumpAndSettle();

    // Leave the sync screen while the device is still being removed.
    Navigator.of(tester.element(find.byType(SyncScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsNothing);
    engine.removeDone!.complete();
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['remove other', 'rekey a brand new passphrase']);
    await openSync(tester);
    expect(find.text('Write this down'), findsOneWidget);
    expect(find.text('REKE-YED0-0000-0000-0000-0000-0000-0002'), findsOneWidget);
  });

  testWidgets('the vault can be re-keyed on its own from the sync screen', (tester) async {
    final engine = FakeEngine()..configured();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);
    await tapVisible(tester, find.byKey(const Key('sync-rekey')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sync-rekey-passphrase')), 'a brand new passphrase');
    await tester.enterText(find.byKey(const Key('sync-rekey-confirm')), 'a brand new passphrase');
    await tester.tap(find.byKey(const Key('sync-rekey-confirm-button')));
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['rekey a brand new passphrase']);
    expect(find.text('REKE-YED0-0000-0000-0000-0000-0000-0002'), findsOneWidget);
  });

  testWidgets('a device removed elsewhere says so plainly and can disconnect', (tester) async {
    final engine = FakeEngine()
      ..needsAttention(SyncAttention.removed, 'This device was removed from the vault on another device, so it no longer syncs.')
      ..disconnectDone = Completer<void>();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.text('Sync stopped: this device was removed'), findsOneWidget, reason: 'the hosts status line');
    await openSync(tester);
    expect(find.text('This device was removed from the vault'), findsOneWidget);
    expect(find.byKey(const Key('sync-unlock-passphrase')), findsNothing, reason: 'no passphrase helps here');
    await scrollTo(tester, find.byKey(const Key('sync-rekey')));
    final rekey = tester.widget<TextButton>(find.byKey(const Key('sync-rekey')));
    expect(rekey.onPressed, isNull, reason: 'not while sync is stopped');
    final disconnect = find.byKey(const Key('sync-removed-disconnect'));
    await tester.scrollUntilVisible(disconnect, -150, scrollable: find.byType(Scrollable).first);
    await tapVisible(tester, disconnect);
    await tester.pump();
    // A sync still running holds the disconnect up; the screen keeps
    // drawing meanwhile, with the button off so it isn't pressed twice.
    expect(engine.syncCalls, ['disconnect']);
    expect(tester.widget<FilledButton>(disconnect).onPressed, isNull);
    engine.disconnectDone!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Where should Promptly keep your vault?'), findsOneWidget, reason: 'ready to join again');
  });

  testWidgets('a host kept on this device only is saved that way, before its password', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await addHost(tester);
    await tester.enterText(find.byKey(const Key('host-label')), 'nas');
    await tester.enterText(find.byKey(const Key('host-hostname')), 'nas.local');
    await tester.enterText(find.byKey(const Key('host-username')), 'admin');
    await tester.tap(find.text('Password'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('host-password')), 'hunter2');
    await scrollTap(tester, find.text('Remember the password on this device'));
    await tester.pumpAndSettle();
    final local = find.byKey(const Key('host-local-only'));
    expect(tester.widget<SwitchListTile>(local).value, isFalse, reason: 'hosts sync by default');
    await scrollTap(tester, local);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-save')));
    await tester.pumpAndSettle();
    expect(engine.records['hosts']!.values.single, contains('"sync":"local_only"'));
    expect(engine.secrets.values.single, 'hunter2');
    expect(engine.writes, ['record hosts', 'secret'], reason: 'the host says where its password may go first');

    // Editing it again shows the switch on; turning it off lets it sync.
    await tester.tap(find.byTooltip('Host actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await scrollTo(tester, local);
    expect(tester.widget<SwitchListTile>(local).value, isTrue);
    await scrollTap(tester, local);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-save')));
    await tester.pumpAndSettle();
    expect(engine.records['hosts']!.values.single, contains('"sync":"vault"'));
    expect(engine.secrets.values.single, 'hunter2', reason: 'nothing is lost switching');
  });

  testWidgets('a key can be kept on this device only, and switched either way later', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keys').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('keys-generate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('key-label')), 'yubi-ish');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('key-local-only'))).value, isFalse,
        reason: 'keys go in the vault by default');
    await tester.tap(find.byKey(const Key('key-local-only')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('key-generate-ok')));
    await tester.pumpAndSettle();
    String json() => engine.records['identities']!.values.single;
    expect(json(), contains('"sync":"local_only"'));
    expect(engine.writes, ['record identities', 'secret'], reason: 'the key says where it may go first');
    expect(find.textContaining('this device only'), findsOneWidget);

    await tester.tap(find.byTooltip('Key actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync with the vault'));
    await tester.pumpAndSettle();
    expect(json(), contains('"sync":"vault"'));
    expect(engine.secrets.length, 1, reason: 'nothing is deleted');
    await tester.tap(find.byTooltip('Key actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep on this device only'));
    await tester.pumpAndSettle();
    expect(json(), contains('"sync":"local_only"'));
    expect(engine.secrets.length, 1);
  });

  testWidgets('a vault from a newer Promptly says to update and points at the update check', (tester) async {
    final engine = FakeEngine()..needsAttention(SyncAttention.updateNeeded, 'Update Promptly on this device.');
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);
    expect(find.text('Promptly needs an update'), findsOneWidget);
    expect(find.byKey(const Key('sync-unlock')), findsNothing);
    await tapVisible(tester, find.byKey(const Key('sync-check-updates')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
  });

  testWidgets('pulling the hosts list down syncs, and coming back to the front asks for a sync', (tester) async {
    final engine = FakeEngine()..records['hosts'] = {'h1': hostJson('h1', 'web-1'), 'h2': hostJson('h2', 'nas')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pull-to-sync')), findsNothing, reason: 'nothing to sync with yet');
    engine._configured('/shared/vault', 'test-box (Linux)');
    await tester.pumpAndSettle();
    await tester.fling(find.text('web-1'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(engine.syncCalls, ['sync-now']);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(engine.syncCalls.last, 'wake');
    // A window flicking in and out of focus does not sync each time.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.syncCalls.where((c) => c == 'wake').length, 1);
  });

  testWidgets('settings changed on another device show once its changes land', (tester) async {
    final engine = FakeEngine()..configured();
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);

    // The other device's choice is in the store, but nothing has said so yet.
    engine.settings['theme_mode'] = '"dark"';
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);

    engine.landChanges();
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
  });

  testWidgets('snippets changed on another device show once its changes land', (tester) async {
    final engine = FakeEngine()
      ..configured()
      ..records['snippets'] = {'s1': snippetJson('s1', 'deploy', 'make deploy')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(container.read(snippetsProvider).single.command, 'make deploy');

    engine.records['snippets'] = {'s1': snippetJson('s1', 'deploy', 'make deploy-v2')};
    engine.landChanges();
    await tester.pumpAndSettle();
    expect(container.read(snippetsProvider).single.command, 'make deploy-v2', reason: 'a stale copy would overwrite it');
  });

  testWidgets('the sync screen shows files that could not be read yet in plain words', (tester) async {
    final engine = FakeEngine();
    engine.sync = SyncStatus(
      configured: true,
      kind: SyncBackendKind.localFolder,
      location: '/shared/vault',
      vaultId: 'vault-1',
      deviceId: 'this-device',
      deviceName: 'test-box (Linux)',
      syncing: false,
      lastSyncAt: DateTime.now().toUtc().toIso8601String(),
      warnings: const ['7f3a/000004.seg: the file is damaged or was tampered with'],
      pendingOps: 0,
      devices: const [],
      vaultBytes: 100,
      changes: 0,
    );
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await openSync(tester);
    expect(find.byKey(const Key('sync-warnings')), findsOneWidget);
    expect(find.textContaining('000004.seg'), findsOneWidget);
    await tester.fling(find.byKey(const Key('sync-summary')), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(engine.syncCalls.last, 'sync-now', reason: 'the sync screen pulls to refresh too');
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

  testWidgets("a host set to no login keeps it over its group's default key", (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['groups'] = {
      'g1': '{"id":"g1","label":"Tailnet","parent_id":null,"color":null,"defaults":{"identity_id":"k1"}}',
    };
    engine.records['identities'] = {
      'k1': '{"id":"k1","label":"laptop","key_type":"ed25519","public_key":"ssh-ed25519 AAAA","private_key_secret_id":"s1"}',
    };
    engine.secrets['s1'] = '-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----';
    engine.records['hosts'] = {
      'h1': hostJson('h1', 'nas', group: 'g1', auth: '{"kind":"none"}'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    expect(find.textContaining('no login'), findsOneWidget);
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    final request = engine.requests.single;
    expect(request.auth, SshAuthKind.interactive);
    expect(request.privateKey, isNull);
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

  testWidgets('every menu opens below the menu bar, inside the window, with room after the shortcuts', (tester) async {
    for (final height in [900.0, 600.0]) {
      tester.view.physicalSize = Size(1400, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(FakeEngine()));
      await tester.pumpAndSettle();
      final barBottom = tester.getBottomLeft(find.byType(MenuBar)).dy;
      for (final name in ['File', 'Edit', 'View', 'Session', 'Help']) {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
        // The open menu is the panel holding the menu's items.
        final items = find.byType(MenuItemButton);
        expect(items, findsWidgets, reason: '$name opens');
        final top = tester.getTopLeft(items.first).dy;
        expect(top, greaterThanOrEqualTo(barBottom), reason: '$name at $height high must not cover the bar');
        final panel = find.ancestor(of: items.first, matching: find.byType(SingleChildScrollView)).first;
        final bottom = tester.getBottomLeft(panel).dy;
        expect(bottom, lessThanOrEqualTo(height), reason: '$name stays inside the window');
        for (final item in tester.widgetList<MenuItemButton>(items)) {
          if (item.shortcut == null) continue;
          final f = find.byWidget(item);
          if (tester.getRect(f).bottom > height) continue;
          final label = find.descendant(of: f, matching: find.byType(Text)).last;
          expect(
            tester.getTopRight(f).dx - tester.getTopRight(label).dx,
            greaterThanOrEqualTo(16),
            reason: '$name: shortcut ${(tester.widget<Text>(label)).data} needs room on its right',
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
    }
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
    expect(engine.fileCalls.last, 'upload /home/me/local.txt /home/ops/local.txt', reason: 'nothing there to replace');
  });

  testWidgets('a desktop copy asks before replacing a file and cleans a server name', (tester) async {
    desktopWindow(tester);
    final local = MemoryFs({
      '/home/me': [
        const FsEntry(name: 'notes.txt', path: '/home/me/notes.txt', isDir: false, size: 10),
        const FsEntry(name: 'local.txt', path: '/home/me/local.txt', isDir: false, size: 10),
      ],
    });
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    engine.remoteFiles['/home/ops']!.add(
      FileEntry(
        name: 'LOCAL.TXT',
        isDir: false,
        isSymlink: false,
        size: BigInt.one,
        modified: BigInt.zero,
        permissions: 0x1A4,
        owner: 'ops',
        group: 'ops',
      ),
    );
    engine.remoteFiles['/home/ops']!.add(
      FileEntry(
        name: r'..\..\.bashrc',
        isDir: false,
        isSymlink: false,
        size: BigInt.one,
        modified: BigInt.zero,
        permissions: 0x1A4,
        owner: 'ops',
        group: 'ops',
      ),
    );
    await tester.pumpWidget(appWith(engine, localDir: '/home/me', localFs: local));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-files')));
    await tester.pumpAndSettle();
    final calls = engine.fileCalls.length;
    Future<void> download(String name) async {
      await tester.tap(
        find.descendant(of: find.byKey(Key('remote-entry-$name')), matching: find.byKey(Key('entry-menu-$name'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download to this device'));
      await tester.pumpAndSettle();
    }

    // notes.txt is on both sides: copying it here asks, and Cancel keeps ours.
    await download('notes.txt');
    expect(find.text('Replace notes.txt?'), findsOneWidget);
    expect(find.textContaining('This folder on this device'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.length, calls, reason: 'nothing copied');
    await download('notes.txt');
    await tester.tap(find.byKey(const Key('files-replace-ok')));
    await tester.pumpAndSettle();
    expect(engine.fileCalls.last, 'download /home/ops/notes.txt /home/me/notes.txt (replace)');

    // A name a server made up to climb out of the folder stays in it.
    await download(r'..\..\.bashrc');
    expect(engine.fileCalls.last, r'download /home/ops/..\..\.bashrc /home/me/.bashrc');

    // On a Mac, LOCAL.TXT would land on local.txt, so that asks too.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await download('LOCAL.TXT');
    expect(find.text('Replace LOCAL.TXT?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    await download('LOCAL.TXT');
    expect(find.text('Replace LOCAL.TXT?'), findsNothing, reason: 'another file on Linux');
    expect(engine.fileCalls.last, 'download /home/ops/LOCAL.TXT /home/me/LOCAL.TXT');
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
    expect(find.text('Version $appVersion · engine 9.9.9-test'), findsOneWidget);
    await scrollTap(tester, find.byKey(const Key('about-licences')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('about checks for updates and says what to do with one', (tester) async {
    final updates = FakeUpdateService(const Release(version: appVersion, pageUrl: releasesPage));
    await tester.pumpWidget(appWith(FakeEngine(), updates: updates));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('settings-about')));
    await tester.pumpAndSettle();
    expect(updates.checks, 0, reason: 'nothing is asked until Check is pressed');

    await tester.tap(find.byKey(const Key('update-check-now')));
    await tester.pumpAndSettle();
    expect(find.text('Promptly is up to date'), findsOneWidget);

    updates.release = const Release(
      version: '99.0.0',
      pageUrl: releasesPage,
      windowsInstaller: ReleaseAsset(name: 'promptly-99.0.0$windowsInstallerSuffix', url: 'https://x', size: 1),
    );
    installedByInstallerOverride = false;
    addTearDown(() => installedByInstallerOverride = null);
    await tester.tap(find.byKey(const Key('update-check-now')));
    await tester.pumpAndSettle();
    expect(find.text('Version 99.0.0 is out'), findsOneWidget);
    expect(find.byKey(const Key('update-open-page')), findsOneWidget, reason: 'a copy from the zip downloads by hand');
    expect(find.byKey(const Key('update-install')), findsNothing);

    // Installed with the installer, it offers to update itself.
    installedByInstallerOverride = true;
    await tester.tap(find.byTooltip('Back to settings'));
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('settings-about')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-install')), findsOneWidget);
  });

  testWidgets('the automatic update check is off until turned on, then reminds once', (tester) async {
    final engine = FakeEngine();
    final updates = FakeUpdateService(const Release(version: '99.0.0', pageUrl: releasesPage));
    await tester.pumpWidget(appWith(engine, updates: updates));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(updates.checks, 0);

    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('update-check')));
    await tester.pumpAndSettle();
    expect(engine.settings['update_check'], 'true');

    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(updates.checks, 1);
    expect(find.text('Promptly 99.0.0 is out.'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('Promptly 99.0.0 is out.'), findsNothing, reason: 'the reminder goes by itself');

    // A day later it looks again, but does not repeat itself.
    await tester.pump(const Duration(days: 1));
    await tester.pump();
    expect(updates.checks, 2);
    expect(find.text('Promptly 99.0.0 is out.'), findsNothing);

    // Off again: no more checks.
    await scrollTap(tester, find.byKey(const Key('update-check')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(days: 2));
    expect(updates.checks, 2);
  });

  testWidgets('Settings says when saved data is not encrypted, or locked', (tester) async {
    final engine = FakeEngine();
    await tester.pumpWidget(appWith(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('settings-about')));
    expect(find.byKey(const Key('secrets-state'), skipOffstage: false), findsNothing);

    for (final (state, text) in [
      (SecretsState.plain, 'Your data on this device is not encrypted'),
      (SecretsState.locked, 'Saved passwords and keys are locked'),
    ]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(appWith(FakeEngine()..secretsKept = state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('secrets-state')));
      expect(find.text(text), findsOneWidget);
    }
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
    // Settings is long at this size: bigger steps reach its end.
    Future<void> farTap(Finder finder) async {
      await tester.scrollUntilVisible(finder, 400, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(finder);
    }

    await farTap(find.byKey(const Key('terminal-font')));
    await tester.pumpAndSettle();
    expect(find.text('Terminal font'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to settings'));
    await tester.pumpAndSettle();
    await farTap(find.byKey(const Key('settings-help')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to settings'));
    await tester.pumpAndSettle();
    await farTap(find.byKey(const Key('settings-about')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hosts').first);
    await tester.pumpAndSettle();
    await addHost(tester);
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

  testWidgets('a failed connection says what happened and what to try, with the details behind a button', (
    tester,
  ) async {
    final engine = FakeEngine()
      ..failWith = const SshEvent(
        kind: SshEventKind.failed,
        secretForKey: false,
        error: 'could not reach web-1.example on port 22: nothing is listening there',
        errorTitle: 'Nothing is answering on port 22',
        errorHint: 'Check the port number, and that the SSH server is running on web-1.example.',
      );
    engine.records['hosts'] = {'h1': hostJson('h1', 'web-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing is answering on port 22'), findsOneWidget);
    expect(find.textContaining('SSH server is running'), findsOneWidget);
    expect(find.textContaining('nothing is listening there'), findsNothing, reason: 'the detail waits behind Details');
    await tester.tap(find.byKey(const Key('connect-error-details')));
    await tester.pumpAndSettle();
    expect(find.textContaining('nothing is listening there'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets("a group's port and jump host are set in its editor and used by its hosts", (tester) async {
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.secrets['p1'] = 'hunter2';
    engine.records['groups'] = {'g1': '{"id":"g1","label":"Production","parent_id":null,"color":null,"defaults":{}}'};
    engine.records['hosts'] = {
      'b1': hostJson('b1', 'bastion', auth: '{"kind":"password","password_secret_id":"p1"}'),
      'h1': hostJson(
        'h1',
        'web-1',
        group: 'g1',
      ).replaceFirst('"keepalive_seconds":30', '"keepalive_seconds":0'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-edit-g1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('group-port')), '2222');
    await tester.ensureVisible(find.byKey(const Key('group-jump')));
    await tester.tap(find.byKey(const Key('group-jump')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bastion').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-save')));
    await tester.pumpAndSettle();
    final group = engine.records['groups']!['g1']!;
    expect(group, contains('"port":2222'));
    expect(group, contains('"jump_host_id":"b1"'));

    expect(find.textContaining('ops@web-1.example:2222'), findsOneWidget, reason: 'the list shows the port in use');
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    final r = engine.requests.single;
    expect(r.port, 2222, reason: 'a host left on 22 takes the group port');
    expect(r.jumps.single.host, 'bastion.example');
    expect(r.jumps.single.password, 'hunter2');
    expect(r.keepaliveSeconds, 0, reason: 'zero is passed on, to turn keep-alives off');
  });

  testWidgets("the host editor shows what the group fills in: user, port, key and jump host", (tester) async {
    final engine = FakeEngine();
    engine.records['groups'] = {
      'g1':
          '{"id":"g1","label":"Production","parent_id":null,"color":null,'
          '"defaults":{"username":"ops-default","identity_id":"k1","port":2222,"jump_host_id":"b1"}}',
    };
    engine.records['identities'] = {
      'k1': '{"id":"k1","label":"laptop","key_type":"ed25519","public_key":"ssh-ed25519 AAAA","private_key_secret_id":"s1"}',
    };
    engine.records['hosts'] = {
      'b1': hostJson('b1', 'bastion'),
      'h1': hostJson('h1', 'web-1', group: 'g1').replaceFirst('"username":"ops"', '"username":""'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('host-row-h1')), matching: find.byTooltip('Host actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text("Blank uses the group's ops-default"), findsOneWidget);
    expect(find.byKey(const Key('host-port-inherited')), findsOneWidget);
    expect(find.text("Uses the group's key, laptop."), findsOneWidget, reason: 'the host asks each time');
    await scrollTo(tester, find.byKey(const Key('host-jump')));
    expect(find.text("The group's: bastion"), findsOneWidget);
  });

  testWidgets('tags are saved from the host editor, and search finds hosts by tag and by notes', (tester) async {
    final engine = FakeEngine();
    engine.records['hosts'] = {
      'h1': hostJson('h1', 'web-1'),
      'h2': hostJson('h2', 'nas').replaceFirst('"notes":""', '"notes":"The box under the stairs"'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Host actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('host-tags')));
    await tester.enterText(find.byKey(const Key('host-tags')), 'eu-west, frontend,  , Frontend');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Chip, 'eu-west'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'frontend'), findsOneWidget);
    await tester.tap(find.byKey(const Key('host-save')));
    await tester.pumpAndSettle();
    expect(engine.records['hosts']!['h1'], contains('"tags":["eu-west","frontend"]'));

    final search = find.byType(TextField).first;
    await tester.enterText(search, 'front');
    await tester.pumpAndSettle();
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('nas'), findsNothing);
    await tester.enterText(search, 'stairs');
    await tester.pumpAndSettle();
    expect(find.text('nas'), findsOneWidget);
    expect(find.text('web-1'), findsNothing);
  });

  testWidgets('Test connection runs the real steps with the form as it stands, then hangs up', (tester) async {
    final engine = FakeEngine()..connectedSessionId = 9;
    engine.records['hosts'] = {
      'h1': hostJson(
        'h1',
        'web-1',
        auth: '{"kind":"password"}',
      ).replaceFirst('"startup_command":null', '"startup_command":"htop"'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Host actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('host-hostname')), 'web-2.example');
    await tester.enterText(find.byType(TextFormField).at(4), 'typed-secret');
    await scrollTap(tester, find.byKey(const Key('host-test')));
    await tester.pumpAndSettle();
    expect(find.text('Test connection'), findsWidgets);
    expect(find.byKey(const Key('host-test-ok')), findsOneWidget);
    expect(find.text('Connecting'), findsOneWidget, reason: 'the steps are shown');
    final r = engine.requests.single;
    expect(r.host, 'web-2.example', reason: 'the unsaved form is what gets tested');
    expect(r.password, 'typed-secret');
    expect(r.startupCommand, isNull, reason: 'a test runs nothing on the server');
    expect(r.forwards, isEmpty);
    expect(engine.cancelledAttempts, [1], reason: 'the test session is hung up');
    await tester.tap(find.byKey(const Key('host-test-close')));
    await tester.pumpAndSettle();
    expect(find.text('Edit host'), findsOneWidget);
    expect(engine.records['hosts']!['h1'], contains('"hostname":"web-1.example"'), reason: 'nothing was saved');
  });

  testWidgets('a production host is marked in the editor, and its sessions and tabs carry a red bar with the label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final engine = FakeEngine()..connectedSessionId = 7;
    engine.records['hosts'] = {'h1': hostJson('h1', 'db-1')};
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Host actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await scrollTap(tester, find.byKey(const Key('host-production')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('host-production-label')));
    await tester.enterText(find.byKey(const Key('host-production-label')), 'Live payments');
    await tester.tap(find.byKey(const Key('host-save')));
    await tester.pumpAndSettle();
    final saved = engine.records['hosts']!['h1']!;
    expect(saved, contains('"production":true'));
    expect(saved, contains('"production_label":"Live payments"'));

    // On a desktop window, so the session opens in a tab.
    desktopWindow(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-row-h1')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('production-bar')), findsOneWidget);
    expect(find.text('LIVE PAYMENTS'), findsWidgets, reason: 'the bar and the tab say it in words');
    expect(find.byKey(const Key('tab-production')), findsOneWidget);
    expect(find.bySemanticsLabel('Production host: Live payments'), findsOneWidget);
    expect(find.byKey(const Key('host-colour-bar')), findsNothing, reason: 'the red bar replaces the colour strip');
    handle.dispose();
  });

  testWidgets('while reconnecting the status dot is amber, says so, and pulses unless motion is reduced', (
    tester,
  ) async {
    Future<double> opacityAfter(Duration d) async {
      await tester.pump(d);
      final fade = tester.widget<FadeTransition>(
        find.descendant(of: find.byType(SessionStatusDot), matching: find.byType(FadeTransition)).first,
      );
      return fade.opacity.value;
    }

    for (final reduced in [false, true]) {
      if (reduced) {
        tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
          disableAnimations: true,
        );
      }
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
      expect(find.text('Connection dropped'), findsOneWidget);
      expect(find.byTooltip('Reconnecting…'), findsOneWidget);
      final dot = tester.widget<Container>(
        find.descendant(of: find.byType(SessionStatusDot), matching: find.byType(Container)).first,
      );
      final context = tester.element(find.byType(SessionStatusDot).first);
      expect((dot.decoration! as BoxDecoration).color, context.tokens.warning);
      final a = await opacityAfter(const Duration(milliseconds: 200));
      final b = await opacityAfter(const Duration(milliseconds: 300));
      if (reduced) {
        expect([a, b], [1.0, 1.0], reason: 'steady with reduced motion');
      } else {
        expect(a, isNot(b), reason: 'it pulses');
      }
      // Let the reconnect finish so nothing is left running.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Connected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });

  testWidgets('the host and group editors fit a 360-wide phone at double text size', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final engine = FakeEngine();
    engine.records['groups'] = {
      'g1':
          '{"id":"g1","label":"Production","parent_id":null,"color":null,'
          '"defaults":{"username":"ops-default","identity_id":"k1","port":2222,"jump_host_id":"b1"}}',
    };
    engine.records['identities'] = {
      'k1':
          '{"id":"k1","label":"a key with a rather long name","key_type":"ed25519","public_key":"ssh-ed25519 AAAA","private_key_secret_id":"s1"}',
    };
    engine.records['hosts'] = {
      'b1': hostJson('b1', 'bastion-with-a-long-name'),
      'h1': hostJson(
        'h1',
        'web-1',
        group: 'g1',
        extra: ',"production":true,"production_label":"Production database"',
      ).replaceFirst('"tags":[]', '"tags":["eu-west","frontend"]'),
    };
    await tester.pumpWidget(app(engine));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('host-row-h1')), matching: find.byTooltip('Host actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    for (final key in ['host-tags', 'host-production-label', 'host-jump']) {
      await scrollTo(tester, find.byKey(Key(key)));
    }
    // The test dialog, with a failure in it.
    engine
      ..secrets['s1'] = 'PRIVATE KEY'
      ..failWith = const SshEvent(
        kind: SshEventKind.failed,
        secretForKey: false,
        error: 'jump host bastion: could not find a server called bastion.example',
        errorTitle: 'Couldn\'t connect to the jump host bastion.example',
        errorHint: 'Check the hostname for typos, and that this device is online (or on the VPN the server needs).',
      );
    await tester.scrollUntilVisible(
      find.byKey(const Key('host-test')),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-test')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connect-error-title')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('connect-error-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-error-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-test-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-edit-g1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('group-jump')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-port')), findsOneWidget);
    // An overflow anywhere above would have failed the test.
  });
  group('terminal settings', () {
    /// Open a local shell from the Sessions tab.
    Future<void> openShell(WidgetTester tester, FakeEngine engine) async {
      await tester.pumpWidget(app(engine));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sessions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(RegExp('^(Open a l|L)ocal shell')).first);
      await tester.pumpAndSettle();
    }

    testWidgets('the bell flashes the terminal briefly', (tester) async {
      final engine = FakeEngine()..connectedSessionId = 1;
      await openShell(tester, engine);
      expect(find.byKey(const Key('bell-flash')), findsNothing);
      engine.emitText(1, 'ding', bell: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('bell-flash')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bell-flash')), findsNothing, reason: 'it fades');
      engine.emitText(1, 'quiet');
      await tester.pump();
      expect(find.byKey(const Key('bell-flash')), findsNothing, reason: 'only a bell flashes');
    });

    testWidgets('with reduced motion the bell is an outline, not a flash', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final engine = FakeEngine()..connectedSessionId = 1;
      await openShell(tester, engine);
      engine.emitText(1, 'ding', bell: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('bell-outline')), findsOneWidget);
      expect(find.byKey(const Key('bell-flash')), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('bell-outline')), findsNothing);
    });

    testWidgets('the bell can be off, or vibrate a phone', (tester) async {
      final engine = FakeEngine()
        ..connectedSessionId = 1
        ..settings['terminal_bell'] = '"off"';
      await openShell(tester, engine);
      engine.emitText(1, 'ding', bell: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('bell-flash')), findsNothing);
      expect(find.byKey(const Key('bell-outline')), findsNothing);

      touchPlatformOverride = true;
      addTearDown(() => touchPlatformOverride = null);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method.startsWith('HapticFeedback')) haptics.add(call.method);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final phone = FakeEngine()
        ..connectedSessionId = 1
        ..settings['terminal_bell'] = '"vibrate"';
      await openShell(tester, phone);
      phone.emitText(1, 'ding', bell: true);
      await tester.pump();
      phone.emitText(1, 'ding ding', bell: true);
      await tester.pump();
      expect(haptics, ['HapticFeedback.vibrate'], reason: 'a burst of bells is one buzz');
      expect(find.byKey(const Key('bell-flash')), findsNothing);
    });

    testWidgets('the text size is kept from one session to the next', (tester) async {
      final engine = FakeEngine()
        ..connectedSessionId = 1
        ..settings['terminal_font_size'] = '18.0';
      await openShell(tester, engine);
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.controller.fontSize, 18);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(view.controller.fontSize, 19);
      expect(engine.settings['terminal_font_size'], '19.0');
    });

    testWidgets('sessions draw with the chosen font and ligatures, and the keyboard follows Settings', (tester) async {
      final engine = FakeEngine()..connectedSessionId = 1;
      await openShell(tester, engine);
      var view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.font.family, 'JetBrains Mono');
      expect(view.font.ligatures, isFalse);
      expect(view.font.fallback, contains('Symbols Nerd Font Mono'));
      expect(view.autocorrect, isFalse);

      final chosen = FakeEngine()
        ..connectedSessionId = 1
        ..settings['terminal_font'] = '"Fira Code"'
        ..settings['terminal_ligatures'] = 'true'
        ..settings['terminal_autocorrect'] = 'true';
      await openShell(tester, chosen);
      view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.font.family, 'Fira Code');
      expect(view.font.fallback.first, 'JetBrains Mono', reason: 'the built-in font fills in what it lacks');
      expect(view.font.ligatures, isTrue);
      expect(view.autocorrect, isTrue);
    });

    testWidgets('new sessions keep the scrollback the setting asks for', (tester) async {
      final engine = FakeEngine()..connectedSessionId = 1;
      await openShell(tester, engine);
      expect(engine.scrollback, 10000);

      final more = FakeEngine()
        ..connectedSessionId = 1
        ..settings['terminal_scrollback'] = '50000';
      await openShell(tester, more);
      expect(more.scrollback, 50000);

      final odd = FakeEngine()
        ..connectedSessionId = 1
        ..settings['terminal_scrollback'] = '123';
      await openShell(tester, odd);
      expect(odd.scrollback, 10000, reason: 'a value not offered reads as the usual');
    });

    testWidgets('Ctrl+click on a path copies it instead of opening it', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final engine = FakeEngine()
        ..connectedSessionId = 1
        ..link = '/var/log/syslog';
      await openShell(tester, engine);
      final origin = tester.getTopLeft(find.byType(TerminalView));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final gesture = await tester.startGesture(origin + const Offset(12, 4), kind: PointerDeviceKind.mouse);
      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(copied, '/var/log/syslog');
      expect(find.text('Copied /var/log/syslog'), findsOneWidget);
    });

    testWidgets('Ctrl+click on a link that is not a web link copies it', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final engine = FakeEngine()
        ..connectedSessionId = 1
        ..link = 'ms-msdt:/id PCWDiagnostic';
      await openShell(tester, engine);
      final origin = tester.getTopLeft(find.byType(TerminalView));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final gesture = await tester.startGesture(origin + const Offset(12, 4), kind: PointerDeviceKind.mouse);
      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(copied, 'ms-msdt:/id PCWDiagnostic');
      expect(find.text('Copied ms-msdt:/id PCWDiagnostic'), findsOneWidget);
    });

    testWidgets('a link whose text shows another address asks before opening', (tester) async {
      final engine = FakeEngine()
        ..connectedSessionId = 1
        ..link = 'https://evil.example/login'
        ..linkHidden = true;
      await openShell(tester, engine);
      final origin = tester.getTopLeft(find.byType(TerminalView));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final gesture = await tester.startGesture(origin + const Offset(12, 4), kind: PointerDeviceKind.mouse);
      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsOneWidget);
      expect(find.textContaining('https://evil.example/login'), findsOneWidget, reason: 'the real address is shown');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Open this link?'), findsNothing);
      expect(find.textContaining('Could not open'), findsNothing, reason: 'cancel opens nothing');
    });

    testWidgets('the new settings fit a small phone at double text size', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final engine = FakeEngine();
      // The section on its own, as it sits in the settings list.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [engineProvider.overrideWithValue(engine)],
          child: MaterialApp(
            theme: buildPromptlyTheme(Brightness.light),
            home: Scaffold(
              body: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: const [Card(child: Column(children: [TextChoices(), TerminalChoices()]))],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> pick(String key, String label) async {
        final dropdown = find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byWidgetPredicate((w) => w is DropdownButton),
        );
        await scrollTap(tester, dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await pick('bell', 'Vibrate');
      expect(engine.settings['terminal_bell'], '"vibrate"');
      await pick('font-size', '20');
      expect(engine.settings['terminal_font_size'], '20.0');
      await pick('scrollback', '100,000');
      expect(engine.settings['terminal_scrollback'], '100000');
      // An overflow anywhere above would have failed the test.
    });
  });
}
