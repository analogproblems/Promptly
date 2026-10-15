import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/engine.dart' as rust;
import '../../src/rust/api/files.dart' as rust_files;
import '../../src/rust/api/hosts.dart' as rust_hosts;
import '../../src/rust/api/import.dart' as rust_import;
import '../../src/rust/api/keys.dart' as rust_keys;
import '../../src/rust/api/ssh.dart' as rust_ssh;
import '../../src/rust/api/store.dart' as rust_store;
import '../../src/rust/api/sync.dart' as rust_sync;
import '../../src/rust/api/terminal.dart' as rust_term;
import '../../src/rust/api/themes.dart' as rust_themes;

export '../../src/rust/api/files.dart' show FileEntry, FileTransfer;
export '../../src/rust/api/hosts.dart' show ReachTarget, Reachability;
export '../../src/rust/api/import.dart' show CsvHost, ImportReport, SshConfigHost;
export '../../src/rust/api/keys.dart' show GeneratedKey, KeyInfo, SshKeyKind;
export '../../src/rust/api/store.dart' show StoreRecord;
export '../../src/rust/api/sync.dart' show SyncBackendKind, SyncDevice, SyncSetupResult, SyncStatus;
export '../../src/rust/api/themes.dart' show ThemeInfo;
export '../../src/rust/api/ssh.dart'
    show
        SshAuthKind,
        SshConnectRequest,
        SshEnvVar,
        SshEvent,
        SshEventKind,
        SshExecResult,
        SshForward,
        SshForwardKind,
        SshForwardStatus,
        SshHop,
        SshHostKey,
        SshHostKeyStatus,
        SshKbPrompt,
        SshStep;
export '../../src/rust/api/terminal.dart'
    show
        SessionInfo,
        TerminalCursor,
        TerminalCursorShape,
        TerminalEvent,
        TerminalEventKind,
        TerminalFrame,
        TerminalRow,
        TerminalSearchHit,
        TerminalSelectKind;

/// What the app needs from the Rust engine, as a plain interface so screens
/// can be tested with a fake and so the generated bridge stays in one place.
abstract class Engine {
  String version();
  String ping(String name);
  EndpointParse parseEndpoint(String input);

  /// Start the user's shell in a new session and return its id. `theme` is
  /// a theme id from [themesList].
  int terminalOpenLocal({required int cols, required int rows, required String theme});

  /// Frames and lifecycle events for a session, in order.
  Stream<rust_term.TerminalEvent> terminalEvents(int id);
  void terminalWrite(int id, List<int> data);
  void terminalPaste(int id, String text);
  void terminalResize(int id, int cols, int rows);

  /// Positive scrolls up into history.
  void terminalScroll(int id, int delta);
  void terminalScrollToBottom(int id);
  void terminalSetTheme(int id, String theme);
  void terminalRefresh(int id);

  /// Show a message from Promptly itself in the terminal, such as
  /// "connection dropped". Use `\r\n` for line breaks.
  void terminalNotice(int id, String text);

  /// Text selection in viewport cells; `line` 0 is the top row and may run
  /// past either edge while dragging. `sideRight` is the right half of a cell.
  void terminalSelectBegin(int id, int col, int line, bool sideRight, rust_term.TerminalSelectKind kind);
  void terminalSelectUpdate(int id, int col, int line, bool sideRight);
  void terminalSelectClear(int id);
  String? terminalSelectionText(int id);

  /// Search the screen and scrollback for plain text; null stops searching.
  void terminalSearchSet(int id, String? query);

  /// Move to the next match, up into history when `backward`.
  rust_term.TerminalSearchHit? terminalSearchStep(int id, bool backward);

  /// The link under a viewport cell, if any.
  String? terminalLinkAt(int id, int col, int line);
  void terminalClose(int id);

  /// Where the engine keeps its files. Called once at startup.
  void setDataDir(String path);

  /// The built-in terminal themes, Promptly's own first.
  List<rust_themes.ThemeInfo> themesList();

  /// Register an SSH connection attempt; nothing happens until its events
  /// are subscribed.
  int sshConnectBegin(rust_ssh.SshConnectRequest request);
  Stream<rust_ssh.SshEvent> sshConnectEvents(int attemptId);
  void sshAnswerHostKey(int attemptId, bool trust);
  void sshAnswerSecret(int attemptId, String? secret);
  void sshAnswerKeyboardInteractive(int attemptId, List<String>? answers);
  void sshCancel(int attemptId);

  /// The port forwards of a live SSH session, and whether each is running.
  List<rust_ssh.SshForwardStatus> sshForwards(int sessionId);

  /// Start or stop one forward; returns the port in use when starting.
  Future<int> sshForwardSet(int sessionId, int index, bool enabled);

  /// Run one command on a host with its stored login and no terminal.
  Future<rust_ssh.SshExecResult> sshExec(rust_ssh.SshConnectRequest request, String command, int timeoutSeconds);

  /// Knock on every host's port at once; nothing is sent beyond that.
  Future<List<rust_hosts.Reachability>> hostsReachability(List<rust_hosts.ReachTarget> targets, int timeoutMs);

  // ---- The file browser, over a live session's connection ----------------

  Future<int> filesOpen(int sessionId);
  void filesClose(int id);
  Future<String> filesHome(int id);
  Future<List<rust_files.FileEntry>> filesList(int id, String path);
  Future<void> filesMkdir(int id, String path);
  Future<void> filesRename(int id, String from, String to);
  Future<void> filesDelete(int id, String path);
  Future<void> filesChmod(int id, String path, int mode);

  /// Start a copy; returns the transfer id. `filesTransfers` follows it.
  int filesDownload(int id, String remote, String local);
  int filesUpload(int id, String local, String remote);
  List<rust_files.FileTransfer> filesTransfers(int id);
  void filesClearTransfers(int id);

  /// Records in the local store, as JSON in the vault's format.
  List<rust_store.StoreRecord> recordsList(String collection);
  rust_store.StoreRecord? recordGet(String collection, String id);
  void recordPut(String collection, String id, String json);
  bool recordDelete(String collection, String id);
  String? settingGet(String key);
  void settingSet(String key, String json);

  /// Secrets (passwords, private keys) by id. Never in the record store.
  /// `kind` is `password`, `private_key` or `key_passphrase`.
  void secretPut(String id, String kind, String value);
  String? secretGet(String id);
  void secretDelete(String id);

  rust_keys.GeneratedKey keyGenerate(rust_keys.SshKeyKind kind, String comment);
  rust_keys.KeyInfo keyInspect(String privateKey, String? passphrase);
  String keyFingerprint(String publicKey);

  /// Hosts in the user's ~/.ssh/config, and importing them.
  List<rust_import.SshConfigHost> sshConfigHosts();
  rust_import.ImportReport sshConfigImport(List<String> aliases);

  /// The hosts a CSV file (Termius export, or any with a Hostname column) describes.
  List<rust_import.CsvHost> csvHostsPreview(String text);
  rust_import.ImportReport csvHostsImport(String text, List<int> rows);

  /// Read a theme file (iTerm2, Windows Terminal, Alacritty, base16) without saving.
  List<rust_themes.ThemeInfo> themeImportPreview(String text, String filename);
  rust_themes.ThemeInfo themeSave(rust_themes.ThemeInfo theme);
  void themeDelete(String id);

  /// The vault: where it is, how it is doing, and setting it up.
  rust_sync.SyncStatus syncStatus();
  Stream<rust_sync.SyncStatus> syncEvents();
  bool syncFolderHasVault(String path);
  String syncDefaultDeviceName();
  Future<rust_sync.SyncSetupResult> syncCreateLocalFolder(String path, String passphrase, String deviceName);
  Future<void> syncJoinLocalFolder(String path, {String? passphrase, String? recoveryCode, required String deviceName});
  Future<bool> syncSftpFolderHasVault(String hostId, String remoteDir);
  Future<rust_sync.SyncSetupResult> syncCreateSftp(
    String hostId,
    String remoteDir,
    String passphrase,
    String deviceName,
  );
  Future<void> syncJoinSftp(
    String hostId,
    String remoteDir, {
    String? passphrase,
    String? recoveryCode,
    required String deviceName,
  });
  Future<rust_sync.SyncStatus> syncNow();
  void syncDisconnect();
  Future<void> syncRemoveDevice(String deviceRecordId);
  String? syncQrPayload();
}

sealed class EndpointParse {
  const EndpointParse();
}

class EndpointOk extends EndpointParse {
  const EndpointOk({required this.user, required this.host, required this.port});
  final String user;
  final String host;
  final int port;

  String get display => port == 22 ? '$user@$host' : '$user@$host:$port';
}

class EndpointError extends EndpointParse {
  const EndpointError(this.message);
  final String message;
}

/// The real engine, through flutter_rust_bridge.
class RustEngine implements Engine {
  const RustEngine();

  @override
  String version() => rust.engineVersion();

  @override
  String ping(String name) => rust.ping(name: name);

  @override
  EndpointParse parseEndpoint(String input) {
    try {
      final p = rust.parseEndpoint(input: input);
      return EndpointOk(user: p.user, host: p.host, port: p.port);
    } catch (e) {
      // The engine returns a plain message meant for the UI.
      return EndpointError(e is String ? e : e.toString());
    }
  }

  @override
  int terminalOpenLocal({required int cols, required int rows, required String theme}) =>
      rust_term.terminalOpenLocal(cols: cols, rows: rows, theme: theme);

  @override
  Stream<rust_term.TerminalEvent> terminalEvents(int id) => rust_term.terminalEvents(id: id);

  @override
  void terminalWrite(int id, List<int> data) => rust_term.terminalWrite(id: id, data: data);

  @override
  void terminalPaste(int id, String text) => rust_term.terminalPaste(id: id, text: text);

  @override
  void terminalResize(int id, int cols, int rows) => rust_term.terminalResize(id: id, cols: cols, rows: rows);

  @override
  void terminalScroll(int id, int delta) => rust_term.terminalScroll(id: id, delta: delta);

  @override
  void terminalScrollToBottom(int id) => rust_term.terminalScrollToBottom(id: id);

  @override
  void terminalSetTheme(int id, String theme) => rust_term.terminalSetTheme(id: id, theme: theme);

  @override
  void terminalRefresh(int id) => rust_term.terminalRefresh(id: id);

  @override
  void terminalNotice(int id, String text) => rust_term.terminalNotice(id: id, text: text);

  @override
  void terminalSelectBegin(int id, int col, int line, bool sideRight, rust_term.TerminalSelectKind kind) =>
      rust_term.terminalSelectBegin(id: id, col: col, line: line, sideRight: sideRight, kind: kind);

  @override
  void terminalSelectUpdate(int id, int col, int line, bool sideRight) =>
      rust_term.terminalSelectUpdate(id: id, col: col, line: line, sideRight: sideRight);

  @override
  void terminalSelectClear(int id) => rust_term.terminalSelectClear(id: id);

  @override
  String? terminalSelectionText(int id) => rust_term.terminalSelectionText(id: id);

  @override
  void terminalSearchSet(int id, String? query) => rust_term.terminalSearchSet(id: id, query: query);

  @override
  rust_term.TerminalSearchHit? terminalSearchStep(int id, bool backward) =>
      rust_term.terminalSearchStep(id: id, backward: backward);

  @override
  String? terminalLinkAt(int id, int col, int line) => rust_term.terminalLinkAt(id: id, col: col, line: line);

  @override
  void terminalClose(int id) => rust_term.terminalClose(id: id);

  @override
  void setDataDir(String path) => rust.setDataDir(path: path);

  @override
  List<rust_themes.ThemeInfo> themesList() => rust_themes.themesList();

  @override
  int sshConnectBegin(rust_ssh.SshConnectRequest request) => rust_ssh.sshConnectBegin(request: request);

  @override
  Stream<rust_ssh.SshEvent> sshConnectEvents(int attemptId) => rust_ssh.sshConnectEvents(attemptId: attemptId);

  @override
  void sshAnswerHostKey(int attemptId, bool trust) => rust_ssh.sshAnswerHostKey(attemptId: attemptId, trust: trust);

  @override
  void sshAnswerSecret(int attemptId, String? secret) => rust_ssh.sshAnswerSecret(attemptId: attemptId, secret: secret);

  @override
  void sshAnswerKeyboardInteractive(int attemptId, List<String>? answers) =>
      rust_ssh.sshAnswerKeyboardInteractive(attemptId: attemptId, answers: answers);

  @override
  void sshCancel(int attemptId) => rust_ssh.sshCancel(attemptId: attemptId);

  @override
  List<rust_ssh.SshForwardStatus> sshForwards(int sessionId) => rust_ssh.sshForwards(sessionId: sessionId);

  @override
  Future<int> sshForwardSet(int sessionId, int index, bool enabled) =>
      rust_ssh.sshForwardSet(sessionId: sessionId, index: index, enabled: enabled);

  @override
  Future<rust_ssh.SshExecResult> sshExec(rust_ssh.SshConnectRequest request, String command, int timeoutSeconds) =>
      rust_ssh.sshExec(request: request, command: command, timeoutSeconds: timeoutSeconds);

  @override
  Future<List<rust_hosts.Reachability>> hostsReachability(List<rust_hosts.ReachTarget> targets, int timeoutMs) =>
      rust_hosts.hostsReachability(targets: targets, timeoutMs: timeoutMs);

  @override
  Future<int> filesOpen(int sessionId) => rust_files.filesOpen(sessionId: sessionId);
  @override
  void filesClose(int id) => rust_files.filesClose(id: id);
  @override
  Future<String> filesHome(int id) => rust_files.filesHome(id: id);
  @override
  Future<List<rust_files.FileEntry>> filesList(int id, String path) => rust_files.filesList(id: id, path: path);
  @override
  Future<void> filesMkdir(int id, String path) => rust_files.filesMkdir(id: id, path: path);
  @override
  Future<void> filesRename(int id, String from, String to) => rust_files.filesRename(id: id, from: from, to: to);
  @override
  Future<void> filesDelete(int id, String path) => rust_files.filesDelete(id: id, path: path);
  @override
  Future<void> filesChmod(int id, String path, int mode) => rust_files.filesChmod(id: id, path: path, mode: mode);
  @override
  int filesDownload(int id, String remote, String local) =>
      rust_files.filesDownload(id: id, remote: remote, local: local);
  @override
  int filesUpload(int id, String local, String remote) => rust_files.filesUpload(id: id, local: local, remote: remote);
  @override
  List<rust_files.FileTransfer> filesTransfers(int id) => rust_files.filesTransfers(id: id);
  @override
  void filesClearTransfers(int id) => rust_files.filesClearTransfers(id: id);

  @override
  List<rust_store.StoreRecord> recordsList(String collection) => rust_store.recordsList(collectionName: collection);

  @override
  rust_store.StoreRecord? recordGet(String collection, String id) =>
      rust_store.recordGet(collectionName: collection, id: id);

  @override
  void recordPut(String collection, String id, String json) =>
      rust_store.recordPut(collectionName: collection, id: id, json: json);

  @override
  bool recordDelete(String collection, String id) => rust_store.recordDelete(collectionName: collection, id: id);

  @override
  String? settingGet(String key) => rust_store.settingGet(key: key);

  @override
  void settingSet(String key, String json) => rust_store.settingSet(key: key, json: json);

  @override
  void secretPut(String id, String kind, String value) => rust_store.secretPut(id: id, kind: kind, value: value);

  @override
  String? secretGet(String id) => rust_store.secretGet(id: id);

  @override
  void secretDelete(String id) => rust_store.secretDelete(id: id);

  @override
  rust_keys.GeneratedKey keyGenerate(rust_keys.SshKeyKind kind, String comment) =>
      rust_keys.keyGenerate(kind: kind, comment: comment);

  @override
  rust_keys.KeyInfo keyInspect(String privateKey, String? passphrase) =>
      rust_keys.keyInspect(privateKey: privateKey, passphrase: passphrase);

  @override
  String keyFingerprint(String publicKey) => rust_keys.keyFingerprint(publicKey: publicKey);

  @override
  List<rust_import.SshConfigHost> sshConfigHosts() => rust_import.sshConfigHosts();

  @override
  rust_import.ImportReport sshConfigImport(List<String> aliases) => rust_import.sshConfigImport(aliases: aliases);

  @override
  List<rust_import.CsvHost> csvHostsPreview(String text) => rust_import.csvHostsPreview(text: text);

  @override
  rust_import.ImportReport csvHostsImport(String text, List<int> rows) =>
      rust_import.csvHostsImport(text: text, rows: rows);

  @override
  List<rust_themes.ThemeInfo> themeImportPreview(String text, String filename) =>
      rust_themes.themeImportPreview(text: text, filename: filename);

  @override
  rust_themes.ThemeInfo themeSave(rust_themes.ThemeInfo theme) => rust_themes.themeSave(theme: theme);

  @override
  void themeDelete(String id) => rust_themes.themeDelete(id: id);

  @override
  rust_sync.SyncStatus syncStatus() => rust_sync.syncStatus();

  @override
  Stream<rust_sync.SyncStatus> syncEvents() => rust_sync.syncEvents();

  @override
  bool syncFolderHasVault(String path) => rust_sync.syncFolderHasVault(path: path);

  @override
  String syncDefaultDeviceName() => rust_sync.syncDefaultDeviceName();

  @override
  Future<rust_sync.SyncSetupResult> syncCreateLocalFolder(String path, String passphrase, String deviceName) =>
      rust_sync.syncCreateLocalFolder(path: path, passphrase: passphrase, deviceName: deviceName);

  @override
  Future<void> syncJoinLocalFolder(
    String path, {
    String? passphrase,
    String? recoveryCode,
    required String deviceName,
  }) => rust_sync.syncJoinLocalFolder(
    path: path,
    passphrase: passphrase,
    recoveryCode: recoveryCode,
    deviceName: deviceName,
  );

  @override
  Future<bool> syncSftpFolderHasVault(String hostId, String remoteDir) =>
      rust_sync.syncSftpFolderHasVault(hostId: hostId, remoteDir: remoteDir);

  @override
  Future<rust_sync.SyncSetupResult> syncCreateSftp(
    String hostId,
    String remoteDir,
    String passphrase,
    String deviceName,
  ) => rust_sync.syncCreateSftp(hostId: hostId, remoteDir: remoteDir, passphrase: passphrase, deviceName: deviceName);

  @override
  Future<void> syncJoinSftp(
    String hostId,
    String remoteDir, {
    String? passphrase,
    String? recoveryCode,
    required String deviceName,
  }) => rust_sync.syncJoinSftp(
    hostId: hostId,
    remoteDir: remoteDir,
    passphrase: passphrase,
    recoveryCode: recoveryCode,
    deviceName: deviceName,
  );

  @override
  Future<rust_sync.SyncStatus> syncNow() => rust_sync.syncNow();

  @override
  void syncDisconnect() => rust_sync.syncDisconnect();

  @override
  Future<void> syncRemoveDevice(String deviceRecordId) => rust_sync.syncRemoveDevice(deviceRecordId: deviceRecordId);

  @override
  String? syncQrPayload() => rust_sync.syncQrPayload();
}

final engineProvider = Provider<Engine>((_) => const RustEngine());
