import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/engine.dart' as rust;
import '../../src/rust/api/keys.dart' as rust_keys;
import '../../src/rust/api/ssh.dart' as rust_ssh;
import '../../src/rust/api/store.dart' as rust_store;
import '../../src/rust/api/terminal.dart' as rust_term;
import '../../src/rust/api/themes.dart' as rust_themes;

export '../../src/rust/api/keys.dart' show GeneratedKey, KeyInfo, SshKeyKind;
export '../../src/rust/api/store.dart' show StoreRecord;
export '../../src/rust/api/themes.dart' show ThemeInfo;
export '../../src/rust/api/ssh.dart'
    show
        SshAuthKind,
        SshConnectRequest,
        SshEvent,
        SshEventKind,
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
        TerminalRow;

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

  /// Records in the local store, as JSON in the vault's format.
  List<rust_store.StoreRecord> recordsList(String collection);
  rust_store.StoreRecord? recordGet(String collection, String id);
  void recordPut(String collection, String id, String json);
  bool recordDelete(String collection, String id);
  String? settingGet(String key);
  void settingSet(String key, String json);

  /// Secrets (passwords, private keys) by id. Never in the record store.
  void secretPut(String id, String value);
  String? secretGet(String id);
  void secretDelete(String id);

  rust_keys.GeneratedKey keyGenerate(rust_keys.SshKeyKind kind, String comment);
  rust_keys.KeyInfo keyInspect(String privateKey, String? passphrase);
  String keyFingerprint(String publicKey);
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
  void terminalResize(int id, int cols, int rows) =>
      rust_term.terminalResize(id: id, cols: cols, rows: rows);

  @override
  void terminalScroll(int id, int delta) => rust_term.terminalScroll(id: id, delta: delta);

  @override
  void terminalScrollToBottom(int id) => rust_term.terminalScrollToBottom(id: id);

  @override
  void terminalSetTheme(int id, String theme) => rust_term.terminalSetTheme(id: id, theme: theme);

  @override
  void terminalRefresh(int id) => rust_term.terminalRefresh(id: id);

  @override
  void terminalClose(int id) => rust_term.terminalClose(id: id);

  @override
  void setDataDir(String path) => rust.setDataDir(path: path);

  @override
  List<rust_themes.ThemeInfo> themesList() => rust_themes.themesList();

  @override
  int sshConnectBegin(rust_ssh.SshConnectRequest request) => rust_ssh.sshConnectBegin(request: request);

  @override
  Stream<rust_ssh.SshEvent> sshConnectEvents(int attemptId) =>
      rust_ssh.sshConnectEvents(attemptId: attemptId);

  @override
  void sshAnswerHostKey(int attemptId, bool trust) =>
      rust_ssh.sshAnswerHostKey(attemptId: attemptId, trust: trust);

  @override
  void sshAnswerSecret(int attemptId, String? secret) =>
      rust_ssh.sshAnswerSecret(attemptId: attemptId, secret: secret);

  @override
  void sshAnswerKeyboardInteractive(int attemptId, List<String>? answers) =>
      rust_ssh.sshAnswerKeyboardInteractive(attemptId: attemptId, answers: answers);

  @override
  void sshCancel(int attemptId) => rust_ssh.sshCancel(attemptId: attemptId);

  @override
  List<rust_store.StoreRecord> recordsList(String collection) =>
      rust_store.recordsList(collectionName: collection);

  @override
  rust_store.StoreRecord? recordGet(String collection, String id) =>
      rust_store.recordGet(collectionName: collection, id: id);

  @override
  void recordPut(String collection, String id, String json) =>
      rust_store.recordPut(collectionName: collection, id: id, json: json);

  @override
  bool recordDelete(String collection, String id) =>
      rust_store.recordDelete(collectionName: collection, id: id);

  @override
  String? settingGet(String key) => rust_store.settingGet(key: key);

  @override
  void settingSet(String key, String json) => rust_store.settingSet(key: key, json: json);

  @override
  void secretPut(String id, String value) => rust_store.secretPut(id: id, value: value);

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
}

final engineProvider = Provider<Engine>((_) => const RustEngine());
