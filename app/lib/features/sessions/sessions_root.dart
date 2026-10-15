import 'package:flutter/material.dart';

import '../shell/shell_scaffold.dart';
import '../workspace/workspace_screen.dart';
import 'session_screen.dart';
import 'sessions_screen.dart';

/// The Sessions tab: on a desktop-sized window the workspace of tabs and
/// panes; on a phone the list, or one session filling the screen.
class SessionsRoot extends StatelessWidget {
  const SessionsRoot({super.key, this.sessionId});

  final int? sessionId;

  @override
  Widget build(BuildContext context) {
    if (ShellScaffold.isDesktopLayout(context)) {
      return WorkspaceScreen(showSessionId: sessionId);
    }
    final id = sessionId;
    return id == null ? const SessionsScreen() : SessionScreen(id: id);
  }
}
