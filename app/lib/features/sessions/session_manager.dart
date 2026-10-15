import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../terminal/terminal_controller.dart';

/// One open session as the app sees it.
class SessionEntry {
  SessionEntry({required this.id, required this.controller, required this.isLocal});

  final int id;
  final TerminalController controller;
  final bool isLocal;
}

/// Open sessions, in the order they were opened. Survives navigation: the
/// terminal view is disposable, the controller is not.
class SessionManager extends Notifier<List<SessionEntry>> {
  @override
  List<SessionEntry> build() => [];

  SessionEntry openLocalShell({required bool dark}) {
    final engine = ref.read(engineProvider);
    final id = engine.terminalOpenLocal(cols: 80, rows: 24, dark: dark);
    final entry = SessionEntry(
      id: id,
      isLocal: true,
      controller: TerminalController(engine: engine, id: id, label: 'Local shell'),
    );
    entry.controller.start();
    state = [...state, entry];
    return entry;
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
    entry.controller.dispose();
    try {
      ref.read(engineProvider).terminalClose(id);
    } catch (_) {}
    state = [for (final e in state) if (e.id != id) e];
  }
}

final sessionManagerProvider =
    NotifierProvider<SessionManager, List<SessionEntry>>(SessionManager.new);
