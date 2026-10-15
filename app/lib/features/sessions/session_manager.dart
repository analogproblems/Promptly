import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../terminal/terminal_controller.dart';
import 'connect_flow.dart';

/// One session as the app sees it: connecting, live, reconnecting, failed
/// or exited. Notifies when it changes state; the controller notifies on
/// every frame and the entry passes that on.
class SessionEntry extends ChangeNotifier {
  SessionEntry({required this.id, required this.label, required this.isLocal, this.hostId, this.color});

  /// The app's own id, stable for the session's whole life. Not the engine's.
  final int id;
  String label;
  final bool isLocal;

  /// The saved host this session was opened from, if any.
  final String? hostId;

  /// The host's colour name, so you always know which box you are typing
  /// into. Null for local shells and one-off connections.
  final String? color;

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

  // ---- Reconnecting ----------------------------------------------------

  /// Which try this is, or 0 when not reconnecting.
  int reconnectAttempt = 0;

  /// When the next try starts, or null while a try is in progress.
  DateTime? reconnectAt;
  Timer? _countdown;

  bool get reconnecting => reconnectAttempt > 0;

  /// "Retrying in 4 s · try 3", or "Reconnecting · try 3" during a try.
  String get reconnectStatus {
    final at = reconnectAt;
    if (at != null) {
      final left = at.difference(DateTime.now()).inSeconds;
      if (left > 0) return 'Retrying in $left s · try $reconnectAttempt';
    }
    return 'Reconnecting · try $reconnectAttempt';
  }

  void setReconnect(int attempt, DateTime? at) {
    reconnectAttempt = attempt;
    reconnectAt = at;
    _countdown?.cancel();
    if (at != null) {
      // Keep the countdown text fresh.
      _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (reconnectAt == null || !DateTime.now().isBefore(reconnectAt!)) timer.cancel();
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void clearReconnect() {
    _countdown?.cancel();
    _countdown = null;
    reconnectAttempt = 0;
    reconnectAt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _controller?.dispose();
    _flow?.dispose();
    super.dispose();
  }
}

/// Open sessions, in the order they were opened. Survives navigation: the
/// terminal view is disposable, the entry is not.
class SessionManager extends Notifier<List<SessionEntry>> {
  int _nextId = 1;
  final Map<int, Timer> _retryTimers = {};

  /// Seconds to wait before each try; the last value repeats.
  static const retryDelays = [1, 2, 4, 8, 16, 30];
  static const maxRetries = 10;

  @override
  List<SessionEntry> build() => [];

  /// Open a local shell with the given terminal theme id.
  SessionEntry openLocalShell({required String theme}) {
    final engine = ref.read(engineProvider);
    final entry = SessionEntry(id: _nextId++, label: 'Local shell', isLocal: true);
    try {
      final engineId = engine.terminalOpenLocal(cols: 80, rows: 24, theme: theme);
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
  SessionEntry connectHost(Host host, {required String theme}) {
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
    final entry = SessionEntry(
      id: _nextId++,
      label: host.label,
      isLocal: false,
      hostId: host.id,
      color: host.color ?? defaultColorFor(host.label),
    );
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
      theme: theme,
      label: host.label,
      keepaliveSeconds: host.keepaliveSeconds,
      reattachSessionId: null,
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

  /// Try the same connection again after a failure to connect.
  void retry(int id) {
    final entry = byId(id);
    final request = entry?.flow?.request;
    if (entry == null || request == null) return;
    _startFlow(entry, ref.read(engineProvider), request);
  }

  /// Recolour every live session, for a theme change or a gallery preview.
  void applyTheme(String theme) {
    for (final e in state) {
      final c = e.controller;
      if (c != null && !c.exited) c.setTheme(theme);
    }
  }

  void _startFlow(SessionEntry entry, Engine engine, SshConnectRequest request) {
    final flow = ConnectFlow(engine: engine, request: request);
    entry.setFlow(flow);
    flow.addListener(() => _onFlow(entry, engine, flow));
    flow.start();
  }

  void _onFlow(SessionEntry entry, Engine engine, ConnectFlow flow) {
    if (entry.flow != flow) return; // a newer attempt replaced this one
    final sessionId = flow.sessionId;
    if (sessionId != null) {
      final existing = entry.controller;
      if (existing == null) {
        _attach(entry, engine, sessionId);
      } else if (entry.reconnecting) {
        if (existing.id == sessionId) {
          existing.revive();
        } else {
          // The old session was gone by the time we got back; take the new one.
          existing.dispose();
          _attach(entry, engine, sessionId);
        }
        entry.clearReconnect();
      }
      if (entry.hostId != null) {
        try {
          ref.read(hostsProvider.notifier).markConnected(entry.hostId!);
        } catch (_) {}
      }
    } else if (flow.error != null) {
      if (entry.reconnecting) {
        _reconnectFailed(entry, flow.error!);
      } else if (entry.error == null) {
        entry.setError(flow.error);
      }
    } else if (flow.cancelled && entry.error == null && !entry.reconnecting) {
      entry.setError('Cancelled.');
    }
  }

  void _attach(SessionEntry entry, Engine engine, int sessionId) {
    final c = TerminalController(engine: engine, id: sessionId, label: entry.label)..start();
    entry.setController(c);
    if (!entry.isLocal) c.addListener(() => _watchForDrop(entry, c));
  }

  // ---- Automatic reconnect -----------------------------------------------

  /// An SSH session that ends without an exit status lost its connection
  /// rather than being told to exit: start getting it back.
  void _watchForDrop(SessionEntry entry, TerminalController c) {
    if (!c.exited || c.exitCode != null || entry.reconnecting) return;
    if (entry.controller != c || entry.flow?.request == null) return;
    if (_retryTimers.containsKey(entry.id)) return;
    _scheduleReconnect(entry, attempt: 1);
  }

  void _scheduleReconnect(SessionEntry entry, {required int attempt, bool now = false}) {
    final seconds = now ? 0 : retryDelays[math.min(attempt - 1, retryDelays.length - 1)];
    final delay = Duration(seconds: seconds);
    entry.setReconnect(attempt, seconds == 0 ? null : DateTime.now().add(delay));
    final c = entry.controller;
    if (c != null) {
      final when = seconds == 0 ? 'now' : 'in $seconds s';
      final what = attempt == 1 ? 'Connection dropped. Reconnecting $when' : 'Try $attempt $when';
      c.notice('\r\n\x1b[33m$what…\x1b[0m\r\n');
    }
    _retryTimers[entry.id]?.cancel();
    _retryTimers[entry.id] = Timer(delay, () {
      _retryTimers.remove(entry.id);
      if (byId(entry.id) != entry || !entry.reconnecting) return;
      entry.setReconnect(attempt, null);
      final old = entry.flow!.request;
      final c = entry.controller;
      _startFlow(entry, ref.read(engineProvider), _reattachRequest(old, c));
    });
  }

  void _reconnectFailed(SessionEntry entry, String error) {
    final attempt = entry.reconnectAttempt;
    if (attempt >= maxRetries) {
      entry.clearReconnect();
      entry.setError('Could not reconnect after $attempt tries: $error');
      return;
    }
    _scheduleReconnect(entry, attempt: attempt + 1);
  }

  /// Reconnect straight away, keeping the screen; for the button on an
  /// ended SSH session.
  void reconnectNow(int id) {
    final entry = byId(id);
    if (entry == null || entry.isLocal || entry.flow?.request == null) return;
    _scheduleReconnect(entry, attempt: 1, now: true);
  }

  /// Stop trying. The session stays on screen as ended, with its output.
  void stopReconnect(int id) {
    final entry = byId(id);
    if (entry == null) return;
    _retryTimers.remove(id)?.cancel();
    entry.flow?.cancel();
    entry.clearReconnect();
  }

  SshConnectRequest _reattachRequest(SshConnectRequest r, TerminalController? c) => SshConnectRequest(
        user: r.user,
        host: r.host,
        port: r.port,
        auth: r.auth,
        password: r.password,
        privateKey: r.privateKey,
        passphrase: r.passphrase,
        cols: c != null && c.grid.cols > 0 ? c.grid.cols : r.cols,
        rows: c != null && c.grid.rows > 0 ? c.grid.rows : r.rows,
        theme: r.theme,
        label: r.label,
        keepaliveSeconds: r.keepaliveSeconds,
        reattachSessionId: c?.id,
      );

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
    _retryTimers.remove(id)?.cancel();
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
