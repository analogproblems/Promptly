import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/engine/engine.dart' show TerminalSearchHit;

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/host_colors.dart';
import '../settings/settings_providers.dart';
import '../terminal/terminal_view.dart';
import 'connecting_view.dart';
import 'forwards_sheet.dart';
import 'session_manager.dart';
import 'snippets_drawer.dart';

/// A single session: slim top bar, then nothing but terminal. While an SSH
/// connection is being made, the terminal area shows the progress and any
/// question the server has.
class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  bool _searching = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search');
  TerminalSearchHit? _hit;

  /// True once a query is typed and nothing matched.
  bool _noMatch = false;

  int get id => widget.id;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  SessionEntry? _entry() {
    for (final e in ref.read(sessionManagerProvider)) {
      if (e.id == id) return e;
    }
    return null;
  }

  void _openSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    _entry()?.controller?.searchSet(null);
    _search.clear();
    setState(() {
      _searching = false;
      _hit = null;
      _noMatch = false;
    });
  }

  void _onQuery(String text) {
    final c = _entry()?.controller;
    if (c == null) return;
    c.searchSet(text);
    if (text.trim().isEmpty) {
      setState(() {
        _hit = null;
        _noMatch = false;
      });
      return;
    }
    _step(backward: true);
  }

  void _step({required bool backward}) {
    final c = _entry()?.controller;
    if (c == null) return;
    final hit = c.searchStep(backward: backward);
    setState(() {
      _hit = hit;
      _noMatch = hit == null && _search.text.trim().isNotEmpty;
    });
  }

  Future<void> _openLink(String uri) async {
    final ok = await openExternalLink(uri);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $uri')));
    }
  }

  KeyEventResult _onSearchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeSearch();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _step(backward: !HardwareKeyboard.instance.isShiftPressed);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final entry = ref.watch(sessionManagerProvider.select((s) {
      for (final e in s) {
        if (e.id == id) return e;
      }
      return null;
    }));
    final t = context.tokens;

    if (entry == null) {
      return Center(
        child: Text('This session is closed.', style: TextStyle(color: t.muted)),
      );
    }

    void closeAndLeave() {
      ref.read(sessionManagerProvider.notifier).close(id);
      context.go('/sessions');
    }

    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) {
        final c = entry.controller;
        final live = c != null && !c.exited;
        final accent = entry.color == null ? null : hostColor(entry.color, Theme.of(context).brightness);
        return Column(
          children: [
            if (accent != null)
              Container(key: const Key('host-colour-bar'), height: 3, color: accent),
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(bottom: BorderSide(color: t.border)),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back to sessions',
                    onPressed: () => context.go('/sessions'),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: live
                          ? t.accent
                          : entry.isConnecting
                              ? t.warning
                              : t.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.title,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 13, weight: FontWeight.w600, color: t.text),
                    ),
                  ),
                  if (c != null)
                    Text(
                      '${c.grid.cols}×${c.grid.rows}',
                      style: monoStyle(context, size: 11, color: t.muted),
                    ),
                  if (c != null)
                    IconButton(
                      key: const Key('session-search'),
                      tooltip: 'Search (Ctrl+Shift+F)',
                      onPressed: _searching ? _closeSearch : _openSearch,
                      icon: Icon(_searching ? Icons.search_off : Icons.search),
                    ),
                  if (live)
                    IconButton(
                      key: const Key('session-snippets'),
                      tooltip: 'Snippets',
                      onPressed: () => showSnippetsDrawer(context, ref, entry),
                      icon: const Icon(Icons.code),
                    ),
                  if (live && (entry.flow?.request.forwards.isNotEmpty ?? false))
                    IconButton(
                      key: const Key('session-forwards'),
                      tooltip: 'Port forwards',
                      onPressed: () => showForwardsSheet(context, ref, c.id),
                      icon: const Icon(Icons.alt_route),
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Close session',
                    onPressed: closeAndLeave,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_searching && c != null) _searchBar(context),
            Expanded(
              child: c == null
                  ? (entry.flow != null
                      ? ConnectingView(
                          flow: entry.flow!,
                          onCancel: closeAndLeave,
                          onRetry: () => ref.read(sessionManagerProvider.notifier).retry(id),
                        )
                      : Center(
                          child: Text(entry.error ?? 'Nothing here.', style: TextStyle(color: t.muted)),
                        ))
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        TerminalView(controller: c, onFind: _openSearch, onOpenLink: _openLink),
                        if (entry.reconnecting)
                          _ReconnectOverlay(
                            entry: entry,
                            onStop: () => ref.read(sessionManagerProvider.notifier).stopReconnect(id),
                          )
                        else if (c.exited)
                          _ExitedOverlay(
                            code: c.exitCode,
                            isLocal: entry.isLocal,
                            detail: entry.error,
                            onClose: closeAndLeave,
                            onAgain: () {
                              final manager = ref.read(sessionManagerProvider.notifier);
                              if (entry.isLocal) {
                                final theme = terminalThemeFor(ref, context);
                                manager.close(id);
                                final fresh = manager.openLocalShell(theme: theme);
                                context.go('/sessions/${fresh.id}');
                              } else if (entry.flow?.request != null) {
                                manager.reconnectNow(id);
                              } else {
                                manager.close(id);
                                context.go('/sessions');
                              }
                            },
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  /// Find in the screen and scrollback: a field, the count, up and down.
  Widget _searchBar(BuildContext context) {
    final t = context.tokens;
    final hit = _hit;
    final status = _noMatch
        ? 'No matches'
        : hit == null
            ? ''
            : '${hit.index} of ${hit.total}';
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: t.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Focus(
              onKeyEvent: _onSearchKey,
              child: TextField(
                key: const Key('search-field'),
                controller: _search,
                focusNode: _searchFocus,
                style: monoStyle(context, size: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Find in this session',
                ),
                onChanged: _onQuery,
              ),
            ),
          ),
          Text(status, key: const Key('search-status'), style: TextStyle(fontSize: 12, color: _noMatch ? t.danger : t.muted)),
          IconButton(
            key: const Key('search-prev'),
            tooltip: 'Previous match (Enter)',
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(backward: true),
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
          ),
          IconButton(
            key: const Key('search-next'),
            tooltip: 'Next match (Shift+Enter)',
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(backward: false),
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
          ),
          IconButton(
            key: const Key('search-close'),
            tooltip: 'Close (Esc)',
            visualDensity: VisualDensity.compact,
            onPressed: _closeSearch,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Hand a link to the system. On Linux that is `xdg-open`, which every
/// desktop wires to the person's browser; elsewhere the platform's own
/// opener. False when nothing could take it.
Future<bool> openExternalLink(String uri) async {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.scheme.isEmpty) return false;
  if (!kIsWeb && Platform.isLinux) {
    try {
      final result = await Process.run('xdg-open', [uri]).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) return true;
    } catch (_) {
      // No xdg-open: fall through to the platform opener.
    }
  }
  try {
    return await launchUrl(parsed, mode: LaunchMode.externalApplication).timeout(const Duration(seconds: 5));
  } catch (_) {
    return false;
  }
}

/// Over a session whose connection dropped: what is happening, a way to
/// stop, and any question the new connection asks (a changed host key, a
/// password that is not saved).
class _ReconnectOverlay extends StatelessWidget {
  const _ReconnectOverlay({required this.entry, required this.onStop});

  final SessionEntry entry;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final flow = entry.flow;
    final inProgress = flow != null && entry.reconnectAt == null;
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.sync_problem, color: t.warning),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Connection dropped',
                        style: TextStyle(color: t.text, fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                    ),
                    TextButton(onPressed: onStop, child: const Text('Stop')),
                  ],
                ),
                const SizedBox(height: 4),
                Text(entry.reconnectStatus, style: TextStyle(color: t.muted, fontSize: 13)),
                if (inProgress) ...[
                  const SizedBox(height: 12),
                  Flexible(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                      child: ConnectingView(flow: flow, onCancel: onStop, onRetry: () {}),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExitedOverlay extends StatelessWidget {
  const _ExitedOverlay({
    required this.code,
    required this.isLocal,
    required this.onClose,
    required this.onAgain,
    this.detail,
  });

  final int? code;
  final bool isLocal;
  final VoidCallback onClose;
  final VoidCallback onAgain;

  /// Why, when there is more to say (for example a reconnect that gave up).
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final what = isLocal ? 'The shell' : 'The connection';
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      alignment: Alignment.center,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code == null || code == 0 ? '$what ended.' : '$what ended with code $code.',
                style: TextStyle(color: t.text, fontWeight: FontWeight.w600),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Text(detail!, textAlign: TextAlign.center, style: TextStyle(color: t.muted, fontSize: 13)),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(onPressed: onClose, child: const Text('Close')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: onAgain, child: Text(isLocal ? 'New shell' : 'Reconnect')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
