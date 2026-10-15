import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../terminal/terminal_controller.dart';
import 'connect_flow.dart';

/// One session as the app sees it: connecting, live, failed or exited.
/// Notifies when it changes state; the controller notifies on every frame.
class SessionEntry extends ChangeNotifier {
  SessionEntry({required this.id, required this.label, required this.isLocal, this.hostId});

  /// The app's own id, stable for the session's whole life. Not the engine's.
  final int id;
  String label;
  final bool isLocal;

  /// The saved host this session was opened from, if any.
  final String? hostId;

  TerminalController? _controller;
  ConnectFlow? _flow;
  String? _error;

  TerminalController? get controller => _controller;
  ConnectFlow? get flow => _flow;
  String? get error => _error;

  bool get isLive => _controller != null;
  bool get isConnecting => _controller == null && _flow != null && _error == null;

  String get title => _controller?.title ?? label;

  /// Attach the live terminal. From here on the controller's frames also
  /// notify the entry, so a screen watching the entry sees size and title
  /// changes even if it was built while the session was still connecting.
  void setController(TerminalController c) {
    _controller = c;
    c.addListener(notifyListeners);
    notifyListeners();
  }

  void setFlow(ConnectFlow? f) {
    _flow?.dispose();
    _flow = f;
    _error = null;
    notifyListeners();
  }

  void setError(String? e) {
    _error = e;
    notifyListeners();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _flow?.dispose();
    super.dispose();
  }
}

/// Open sessions, in the order they were opened. Survives navigation: the
/// terminal view is disposable, the entry is not.
class SessionManager extends Notifier<List<SessionEntry>> {
  int _nextId = 1;

  @override
  List<SessionEntry> build() => [];

  SessionEntry openLocalShell({required bool dark}) {
    final engine = ref.read(engineProvider);
    final entry = SessionEntry(id: _nextId++, label: 'Local shell', isLocal: true);
    try {
      final engineId = engine.terminalOpenLocal(cols: 80, rows: 24, dark: dark);
      entry.setController(TerminalController(engine: engine, id: engineId, label: entry.label)..start());
    } catch (e) {
      entry.setError(e is String ? e : e.toString());
    }
    state = [...state, entry];
    return entry;
  }

  /// Start an SSH connection. The entry shows progress and prompts until the
  /// engine reports a session, then becomes a live terminal.
  SessionEntry connectSsh(SshConnectRequest request) {
    final engine = ref.read(engineProvider);
    final label = request.label ?? '${request.user}@${request.host}';
    final entry = SessionEntry(id: _nextId++, label: label, isLocal: false);
    _startFlow(entry, engine, request);
    state = [...state, entry];
    return entry;
  }

  /// Connect to a saved host with its stored auth. A missing key is reported
  /// as an error on the entry rather than thrown.
  SessionEntry connectHost(Host host, {required bool dark}) {
    final engine = ref.read(engineProvider);
    var kind = SshAuthKind.interactive;
    String? password;
    String? privateKey;
    String? problem;
    switch (host.auth.kind) {
      case AuthKind.identity:
        kind = SshAuthKind.key;
        final identity = ref.read(identitiesProvider.notifier).byId(host.auth.identityId);
        final secretId = identity?.privateKeySecretId;
        privateKey = secretId == null ? null : _secret(engine, secretId);
        if (privateKey == null) {
          problem = 'The key for this host is missing. Edit the host and pick a key.';
        }
      case AuthKind.password:
        kind = SshAuthKind.password;
        final secretId = host.auth.passwordSecretId;
        password = secretId == null ? null : _secret(engine, secretId);
      case AuthKind.agent:
      case AuthKind.interactive:
        kind = SshAuthKind.interactive;
    }
    final entry = SessionEntry(id: _nextId++, label: host.label, isLocal: false, hostId: host.id);
    if (problem != null) {
      entry.setError(problem);
      state = [...state, entry];
      return entry;
    }
    final request = SshConnectRequest(
      user: host.username,
      host: host.hostname,
      port: host.port,
      auth: kind,
      password: password,
      privateKey: privateKey,
      passphrase: null,
      cols: 80,
      rows: 24,
      dark: dark,
      label: host.label,
      keepaliveSeconds: host.keepaliveSeconds,
    );
    _startFlow(entry, engine, request);
    state = [...state, entry];
    return entry;
  }

  String? _secret(Engine engine, String id) {
    try {
      return engine.secretGet(id);
    } catch (_) {
      return null;
    }
  }

  /// Try the same connection again after a failure.
  void retry(int id) {
    final entry = byId(id);
    final request = entry?.flow?.request;
    if (entry == null || request == null) return;
    _startFlow(entry, ref.read(engineProvider), request);
  }

  void _startFlow(SessionEntry entry, Engine engine, SshConnectRequest request) {
    final flow = ConnectFlow(engine: engine, request: request);
    entry.setFlow(flow);
    flow.addListener(() {
      if (flow.sessionId != null && entry.controller == null) {
        entry.setController(TerminalController(engine: engine, id: flow.sessionId!, label: entry.label)..start());
        if (entry.hostId != null) {
          try {
            ref.read(hostsProvider.notifier).markConnected(entry.hostId!);
          } catch (_) {}
        }
      } else if (flow.error != null && entry.error == null) {
        entry.setError(flow.error);
      } else if (flow.cancelled && entry.error == null) {
        entry.setError('Cancelled.');
      }
    });
    flow.start();
  }

  SessionEntry? byId(int id) {
    for (final e in state) {
      if (e.id == id) return e;
    }
    return null;
  }

  void close(int id) {
    final entry = byId(id);
    if (entry == null) return;
    final engine = ref.read(engineProvider);
    entry.flow?.cancel();
    final engineId = entry.controller?.id;
    entry.dispose();
    if (engineId != null) {
      try {
        engine.terminalClose(engineId);
      } catch (_) {}
    }
    state = [for (final e in state) if (e.id != id) e];
  }
}

final sessionManagerProvider =
    NotifierProvider<SessionManager, List<SessionEntry>>(SessionManager.new);
