import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart' show TerminalSearchHit;
import '../../core/links.dart';
import '../../core/platform.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/host_colors.dart';
import '../settings/settings_providers.dart';
import '../terminal/keyboard_bar.dart';
import '../terminal/link_kind.dart';
import '../terminal/paste_guard.dart';
import '../terminal/terminal_bell.dart';
import '../terminal/terminal_view.dart';
import '../workspace/workspace.dart' show findRequestProvider;
import 'connecting_view.dart';
import 'forwards_sheet.dart';
import 'session_manager.dart';
import 'snippets_drawer.dart';
import 'status_dot.dart';

/// One session, chrome included: the slim bar with its title and tools,
/// the search bar when open, and the terminal (or the connecting view,
/// or an ended overlay). The phone shows one full screen; the desktop
/// puts one in every pane.
class SessionBody extends ConsumerStatefulWidget {
  const SessionBody({
    super.key,
    required this.entry,
    required this.onClose,
    this.showBack = false,
    this.compact = false,
    this.focused = true,
    this.onFocus,
    this.onReplaced,
    this.onSwitchSession,
  });

  final SessionEntry entry;

  /// Close this session (and, on the phone, leave the screen).
  final VoidCallback onClose;

  /// A back arrow at the left, for the phone's full-screen session.
  final bool showBack;

  /// A lower bar, for panes.
  final bool compact;

  /// Whether requests aimed at "the focused session" (find, from the menu)
  /// apply here.
  final bool focused;

  /// A pointer landed on this session: a pane wants the focus.
  final VoidCallback? onFocus;

  /// "New shell" on an ended local session made another session; show it
  /// where this one was. Defaults to navigating to it.
  final void Function(int sessionId)? onReplaced;

  /// A two-finger swipe on the terminal: show the next session (`1`) or
  /// the one before (`-1`). Only the phone's full-screen session has one.
  final void Function(int step)? onSwitchSession;

  @override
  ConsumerState<SessionBody> createState() => _SessionBodyState();
}

class _SessionBodyState extends ConsumerState<SessionBody> {
  bool _searching = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search');
  TerminalSearchHit? _hit;

  /// True once a query is typed and nothing matched.
  bool _noMatch = false;

  SessionEntry get entry => widget.entry;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    if (entry.controller == null) return;
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    entry.controller?.searchSet(null);
    _search.clear();
    setState(() {
      _searching = false;
      _hit = null;
      _noMatch = false;
    });
  }

  void _onQuery(String text) {
    final c = entry.controller;
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
    final c = entry.controller;
    if (c == null) return;
    final hit = c.searchStep(backward: backward);
    setState(() {
      _hit = hit;
      _noMatch = hit == null && _search.text.trim().isNotEmpty;
    });
  }

  /// A web link opens in the browser; a file path or address is copied,
  /// since it means something on the other machine, not this one.
  Future<void> _openLink(String uri) async {
    if (linkKind(uri) != LinkKind.web) {
      await Clipboard.setData(ClipboardData(text: uri));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $uri')));
      }
      return;
    }
    final ok = await openExternalLink(uri);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $uri')));
    }
  }

  static bool get _touchPlatform => isTouchPlatform;

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

  void _again() {
    final manager = ref.read(sessionManagerProvider.notifier);
    if (entry.isLocal) {
      final theme = terminalThemeFor(ref, context);
      final id = entry.id;
      final fresh = manager.openLocalShell(theme: theme);
      manager.close(id);
      if (widget.onReplaced != null) {
        widget.onReplaced!(fresh.id);
      } else {
        context.go('/sessions/${fresh.id}');
      }
    } else if (entry.flow?.request != null) {
      manager.reconnectNow(entry.id);
    } else {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(findRequestProvider, (_, _) {
      if (widget.focused) _openSearch();
    });
    final t = context.tokens;
    final barHeight = widget.compact ? 34.0 : 44.0;

    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) {
        final c = entry.controller;
        final live = c != null && !c.exited;
        final accent = entry.color == null ? null : hostColor(entry.color, Theme.of(context).brightness);
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: widget.onFocus == null ? null : (_) => widget.onFocus!(),
          child: Column(
            children: [
              if (entry.production != null)
                ProductionBar(label: entry.production!, compact: widget.compact)
              else if (accent != null)
                Container(key: const Key('host-colour-bar'), height: 3, color: accent),
              Container(
                height: barHeight,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: t.surface,
                  border: Border(bottom: BorderSide(color: t.border)),
                ),
                child: Row(
                  children: [
                    if (widget.showBack)
                      IconButton(
                        tooltip: 'Back to sessions',
                        onPressed: () => context.go('/sessions'),
                        icon: const Icon(Icons.arrow_back),
                      )
                    else
                      const SizedBox(width: 8),
                    SessionStatusDot(entry: entry),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.title,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          context,
                          size: widget.compact ? 12 : 13,
                          weight: FontWeight.w600,
                          color: widget.focused ? t.text : t.muted,
                        ),
                      ),
                    ),
                    if (c != null)
                      Text('${c.grid.cols}×${c.grid.rows}', style: monoStyle(context, size: 11, color: t.muted)),
                    if (c != null)
                      IconButton(
                        key: const Key('session-search'),
                        tooltip: 'Search (Ctrl+Shift+F)',
                        visualDensity: widget.compact ? VisualDensity.compact : VisualDensity.standard,
                        onPressed: _searching ? _closeSearch : _openSearch,
                        icon: Icon(_searching ? Icons.search_off : Icons.search, size: widget.compact ? 18 : 24),
                      ),
                    if (live)
                      IconButton(
                        key: const Key('session-snippets'),
                        tooltip: 'Snippets',
                        visualDensity: widget.compact ? VisualDensity.compact : VisualDensity.standard,
                        onPressed: () => showSnippetsDrawer(context, ref, entry),
                        icon: Icon(Icons.code, size: widget.compact ? 18 : 24),
                      ),
                    if (live && !entry.isLocal)
                      IconButton(
                        key: const Key('session-files'),
                        tooltip: 'Files',
                        visualDensity: widget.compact ? VisualDensity.compact : VisualDensity.standard,
                        onPressed: () => context.go('/sessions/${entry.id}/files'),
                        icon: Icon(Icons.folder_open_outlined, size: widget.compact ? 18 : 24),
                      ),
                    if (live && (entry.flow?.request.forwards.isNotEmpty ?? false))
                      IconButton(
                        key: const Key('session-forwards'),
                        tooltip: 'Port forwards',
                        visualDensity: widget.compact ? VisualDensity.compact : VisualDensity.standard,
                        onPressed: () => showForwardsSheet(context, ref, c.id),
                        icon: Icon(Icons.alt_route, size: widget.compact ? 18 : 24),
                      ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Close session',
                      visualDensity: widget.compact ? VisualDensity.compact : VisualDensity.standard,
                      onPressed: widget.onClose,
                      icon: Icon(Icons.close, size: widget.compact ? 18 : 24),
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
                              onCancel: widget.onClose,
                              onRetry: () => ref.read(sessionManagerProvider.notifier).retry(entry.id),
                            )
                          : Center(
                              child: Text(entry.error ?? 'Nothing here.', style: TextStyle(color: t.muted)),
                            ))
                    : Column(
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                TerminalBell(
                                  controller: c,
                                  mode: ref.watch(bellProvider),
                                  child: TerminalView(
                                    controller: c,
                                    autofocus: widget.focused,
                                    onFind: _openSearch,
                                    onOpenLink: _openLink,
                                    onSwitchSession: widget.onSwitchSession,
                                    confirmPaste: (text) =>
                                        confirmPaste(context, text, warn: ref.read(pasteWarningProvider)),
                                  ),
                                ),
                                if (entry.reconnecting)
                                  _ReconnectOverlay(
                                    entry: entry,
                                    onStop: () => ref.read(sessionManagerProvider.notifier).stopReconnect(entry.id),
                                  )
                                else if (c.exited)
                                  _ExitedOverlay(
                                    code: c.exitCode,
                                    isLocal: entry.isLocal,
                                    detail: entry.error,
                                    onClose: widget.onClose,
                                    onAgain: _again,
                                  ),
                              ],
                            ),
                          ),
                          // The keys a phone keyboard lacks, above the system keyboard.
                          if (!widget.compact && !c.exited && _touchPlatform)
                            KeyboardBar(
                              controller: c,
                              onSnippets: live ? () => showSnippetsDrawer(context, ref, entry) : null,
                            ),
                        ],
                      ),
              ),
            ],
          ),
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
          Text(
            status,
            key: const Key('search-status'),
            style: TextStyle(fontSize: 12, color: _noMatch ? t.danger : t.muted),
          ),
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
                  child: Text(
                    detail!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.muted, fontSize: 13),
                  ),
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
