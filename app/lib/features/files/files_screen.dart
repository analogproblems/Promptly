import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/models.dart' show relativeTime;
import '../sessions/session_manager.dart';
import '../shell/shell_scaffold.dart';
import 'fs.dart';

/// Where the local pane starts; tests point it at a folder of their own.
final localStartDirProvider = Provider<String?>((_) => null);

/// This device's files; tests swap in a folder tree in memory.
final localFsProvider = Provider<Fs>((_) => LocalFs());

/// The files of a live session's host. One pane on a phone; on a desktop
/// window this device's files sit beside the server's, and files drag
/// between the two.
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key, required this.sessionId});

  final int sessionId;

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

/// What is being dragged: an entry and which side it came from.
class FsDrag {
  const FsDrag(this.entry, {required this.remote});

  final FsEntry entry;
  final bool remote;
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  int? _browserId;
  String? _error;
  RemoteFs? _remote;
  late final Fs _local = ref.read(localFsProvider);
  late final Engine _engine = ref.read(engineProvider);
  final _remotePane = GlobalKey<_FsPaneState>();
  final _localPane = GlobalKey<_FsPaneState>();
  List<FileTransfer> _transfers = const [];
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final engine = _engine;
    // The browser rides on the engine's session, not the app's number for it.
    final entry = ref.read(sessionManagerProvider).where((e) => e.id == widget.sessionId).firstOrNull;
    final controller = entry?.controller;
    if (controller == null || controller.exited) {
      setState(() => _error = 'The session is not connected. Files need a live connection.');
      return;
    }
    try {
      final id = await engine.filesOpen(controller.id);
      if (!mounted) return;
      setState(() {
        _browserId = id;
        _remote = RemoteFs(engine, id);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is String ? e : e.toString());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    final id = _browserId;
    if (id != null) {
      try {
        _engine.filesClose(id);
      } catch (_) {}
    }
    super.dispose();
  }

  void _watchTransfers() {
    _poll ??= Timer.periodic(const Duration(milliseconds: 300), (_) => _refreshTransfers());
    _refreshTransfers();
  }

  void _refreshTransfers() {
    final id = _browserId;
    if (id == null || !mounted) return;
    List<FileTransfer> now;
    try {
      now = ref.read(engineProvider).filesTransfers(id);
    } catch (_) {
      return;
    }
    final wasRunning = _transfers.any((t) => !t.finished);
    final running = now.any((t) => !t.finished);
    setState(() => _transfers = now);
    if (wasRunning && !running) {
      // Something finished: the lists may have changed.
      _remotePane.currentState?.refresh();
      _localPane.currentState?.refresh();
    }
    if (!running) {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Copy an entry from one side into the other side's current folder.
  void transfer(FsEntry entry, {required bool fromRemote}) {
    final id = _browserId;
    if (id == null) return;
    if (entry.isDir) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Folders cannot be copied yet; open one and copy its files.')));
      return;
    }
    final engine = ref.read(engineProvider);
    try {
      if (fromRemote) {
        final dir = _localPane.currentState?.path;
        if (dir == null) return;
        engine.filesDownload(id, entry.path, _local.join(dir, entry.name));
      } else {
        final dir = _remotePane.currentState?.path;
        if (dir == null) return;
        engine.filesUpload(id, entry.path, _remote!.join(dir, entry.name));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is String ? e : e.toString())));
      return;
    }
    _watchTransfers();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final entry = ref.watch(sessionManagerProvider.select((s) => s.where((e) => e.id == widget.sessionId).firstOrNull));
    final desktop = ShellScaffold.isDesktopLayout(context);
    final title = entry == null ? 'Files' : 'Files on ${entry.label}';

    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: t.danger)),
        ),
      );
    } else if (_remote == null) {
      body = Center(child: Text('Opening the file browser…', style: TextStyle(color: t.muted)));
    } else {
      final remotePane = _FsPane(
        key: _remotePane,
        fs: _remote!,
        startDir: null,
        onTransfer: desktop ? (e) => transfer(e, fromRemote: true) : null,
        onDropped: (d) {
          if (!d.remote) transfer(d.entry, fromRemote: false);
        },
      );
      body = desktop
          ? Row(
              children: [
                Expanded(
                  child: _FsPane(
                    key: _localPane,
                    fs: _local,
                    startDir: ref.read(localStartDirProvider),
                    onTransfer: (e) => transfer(e, fromRemote: false),
                    onDropped: (d) {
                      if (d.remote) transfer(d.entry, fromRemote: true);
                    },
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: t.border),
                Expanded(child: remotePane),
              ],
            )
          : remotePane;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          decoration: BoxDecoration(color: t.surface, border: Border(bottom: BorderSide(color: t.border))),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to the session',
                onPressed: () => context.go('/sessions/${widget.sessionId}'),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(title, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text)),
              ),
              if (desktop)
                Text('Drag files between the two sides to copy them.', style: TextStyle(fontSize: 12, color: t.muted)),
            ],
          ),
        ),
        Expanded(child: body),
        if (_transfers.isNotEmpty) _TransfersBar(transfers: _transfers, onClear: () {
          final id = _browserId;
          if (id != null) ref.read(engineProvider).filesClearTransfers(id);
          _refreshTransfers();
        }),
      ],
    );
  }
}

/// One folder listing with its path, toolbar and entry menus.
class _FsPane extends StatefulWidget {
  const _FsPane({super.key, required this.fs, required this.startDir, this.onTransfer, this.onDropped});

  final Fs fs;
  final String? startDir;

  /// "Copy to the other side", when there is another side.
  final void Function(FsEntry entry)? onTransfer;
  final void Function(FsDrag drag)? onDropped;

  @override
  State<_FsPane> createState() => _FsPaneState();
}

class _FsPaneState extends State<_FsPane> {
  String? path;
  List<FsEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final dir = widget.startDir ?? await widget.fs.home();
      await go(dir);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is String ? e : e.toString();
      });
    }
  }

  Future<void> go(String dir) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.fs.list(dir);
      if (!mounted) return;
      setState(() {
        path = dir;
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is String ? e : e.toString();
      });
    }
  }

  Future<void> refresh() async {
    final p = path;
    if (p != null) await go(p);
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() op) async {
    try {
      await op();
      await refresh();
    } catch (e) {
      _say(e is String ? e : e.toString());
    }
  }

  Future<String?> _askName(String title, {String initial = '', String action = 'OK'}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial, action: action),
    );
    final trimmed = name?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _newFolder() async {
    final p = path;
    if (p == null) return;
    final name = await _askName('New folder', action: 'Create');
    if (name == null) return;
    await _run(() => widget.fs.mkdir(widget.fs.join(p, name)));
  }

  Future<void> _rename(FsEntry e) async {
    final name = await _askName('Rename', initial: e.name, action: 'Rename');
    if (name == null || name == e.name) return;
    await _run(() => widget.fs.rename(e.path, widget.fs.join(widget.fs.parent(e.path), name)));
  }

  Future<void> _delete(FsEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${e.name}?'),
        content: Text(e.isDir ? 'The folder and everything in it are removed. This cannot be undone.' : 'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('files-delete-ok'),
            style: FilledButton.styleFrom(backgroundColor: ctx.tokens.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(() => widget.fs.delete(e.path));
  }

  Future<void> _permissions(FsEntry e) async {
    final mode = await showDialog<int>(context: context, builder: (_) => _PermissionsDialog(name: e.name, mode: e.permissions));
    if (mode == null || mode == e.permissions) return;
    await _run(() => widget.fs.chmod(e.path, mode));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = path;
    final segments = p == null ? const <String>[] : p.split('/').where((s) => s.isNotEmpty).toList();
    final remote = widget.fs.isRemote;
    final side = remote ? 'remote' : 'local';

    Widget list;
    if (_error != null) {
      list = Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: t.danger, fontSize: 13))));
    } else if (_loading && _entries.isEmpty) {
      list = Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: t.muted)));
    } else if (_entries.isEmpty) {
      list = Center(child: Text('Empty folder', style: TextStyle(color: t.muted, fontSize: 13)));
    } else {
      list = ListView.builder(
        itemCount: _entries.length,
        itemBuilder: (context, i) {
          final e = _entries[i];
          final row = _EntryRow(
            key: Key('$side-entry-${e.name}'),
            entry: e,
            onOpen: e.isDir ? () => go(e.path) : null,
            onAction: (action) {
              switch (action) {
                case 'open':
                  if (e.isDir) go(e.path);
                case 'copy':
                  widget.onTransfer?.call(e);
                case 'rename':
                  _rename(e);
                case 'delete':
                  _delete(e);
                case 'permissions':
                  _permissions(e);
              }
            },
            canCopy: widget.onTransfer != null,
            copyLabel: remote ? 'Download to this device' : 'Upload to the server',
          );
          if (widget.onTransfer == null) return row;
          return Draggable<FsDrag>(
            data: FsDrag(e, remote: remote),
            feedback: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: t.surface,
                  border: Border.all(color: t.accent),
                  borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                ),
                child: Text(e.name, style: monoStyle(context, size: 12, color: t.text)),
              ),
            ),
            child: row,
          );
        },
      );
    }

    final pane = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Row(
            children: [
              Text(widget.fs.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: t.muted)),
              const SizedBox(width: 10),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      _Crumb(label: '/', onTap: () => go('/')),
                      for (var i = 0; i < segments.length; i++) ...[
                        Text('›', style: TextStyle(color: t.muted)),
                        _Crumb(
                          label: segments[i],
                          onTap: () => go('/${segments.sublist(0, i + 1).join('/')}'),
                          last: i == segments.length - 1,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                key: Key('$side-up'),
                tooltip: 'Up',
                visualDensity: VisualDensity.compact,
                onPressed: p == null || p == '/' ? null : () => go(widget.fs.parent(p)),
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              IconButton(
                key: Key('$side-refresh'),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                onPressed: refresh,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              IconButton(
                key: Key('$side-new-folder'),
                tooltip: 'New folder',
                visualDensity: VisualDensity.compact,
                onPressed: p == null ? null : _newFolder,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              ),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );

    if (widget.onDropped == null) return pane;
    return DragTarget<FsDrag>(
      onWillAcceptWithDetails: (d) => d.data.remote != remote,
      onAcceptWithDetails: (d) => widget.onDropped!(d.data),
      builder: (context, candidates, _) => Container(
        key: Key('$side-pane'),
        decoration: BoxDecoration(
          border: Border.all(color: candidates.isNotEmpty ? t.accent : Colors.transparent, width: 2),
        ),
        child: pane,
      ),
    );
  }
}

/// A single name, for a new folder or a rename.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial, required this.action});

  final String title;
  final String initial;
  final String action;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('files-name'),
        controller: _controller,
        autofocus: true,
        style: monoStyle(context, size: 14),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('files-name-ok'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.action),
        ),
      ],
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.onTap, this.last = false});

  final String label;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(label, style: monoStyle(context, size: 12, weight: last ? FontWeight.w600 : FontWeight.w400, color: last ? t.text : t.muted)),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onAction,
    required this.canCopy,
    required this.copyLabel,
  });

  final FsEntry entry;
  final VoidCallback? onOpen;
  final void Function(String action) onAction;
  final bool canCopy;
  final String copyLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final e = entry;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: [
            Icon(
              e.isDir ? Icons.folder : (e.isSymlink ? Icons.link : Icons.insert_drive_file_outlined),
              size: 18,
              color: e.isDir ? t.accent : t.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(e.name, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 13, color: t.text)),
            ),
            if (!e.isDir)
              SizedBox(
                width: 72,
                child: Text(formatBytes(e.size), textAlign: TextAlign.right, style: monoStyle(context, size: 11, color: t.muted)),
              ),
            SizedBox(
              width: 64,
              child: Text(
                relativeTime(e.modified),
                textAlign: TextAlign.right,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: monoStyle(context, size: 11, color: t.muted),
              ),
            ),
            PopupMenuButton<String>(
              key: Key('entry-menu-${e.name}'),
              tooltip: 'Actions',
              onSelected: onAction,
              itemBuilder: (_) => [
                if (e.isDir) const PopupMenuItem(value: 'open', child: Text('Open')),
                if (canCopy && !e.isDir) PopupMenuItem(value: 'copy', child: Text(copyLabel)),
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(value: 'permissions', child: Text('Permissions')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
              icon: Icon(Icons.more_vert, size: 18, color: t.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// rwx for owner, group and others, with the octal shown.
class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({required this.name, required this.mode});

  final String name;
  final int mode;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late int _mode = widget.mode & 0x1FF;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    const who = ['Owner', 'Group', 'Others'];
    const what = ['read', 'write', 'run'];
    return AlertDialog(
      title: Text('Permissions of ${widget.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var w = 0; w < 3; w++)
            Row(
              children: [
                SizedBox(width: 64, child: Text(who[w], style: TextStyle(color: t.text))),
                for (var b = 0; b < 3; b++)
                  Row(
                    children: [
                      Checkbox(
                        key: Key('perm-${who[w].toLowerCase()}-${what[b]}'),
                        value: (_mode >> ((2 - w) * 3 + (2 - b))) & 1 == 1,
                        onChanged: (v) => setState(() {
                          final bit = 1 << ((2 - w) * 3 + (2 - b));
                          _mode = v == true ? _mode | bit : _mode & ~bit;
                        }),
                      ),
                      Text(what[b], style: TextStyle(fontSize: 12, color: t.muted)),
                    ],
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Text('${formatMode(_mode)}  ${_mode.toRadixString(8).padLeft(3, '0')}', style: monoStyle(context, size: 13, color: t.muted)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('perm-apply'), onPressed: () => Navigator.pop(context, _mode), child: const Text('Apply')),
      ],
    );
  }
}

class _TransfersBar extends StatelessWidget {
  const _TransfersBar({required this.transfers, required this.onClear});

  final List<FileTransfer> transfers;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shown = transfers.reversed.take(4).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(color: t.surface, border: Border(top: BorderSide(color: t.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Transfers', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: t.muted))),
              TextButton(onPressed: onClear, child: const Text('Clear finished')),
            ],
          ),
          for (final tr in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(tr.upload ? Icons.upload : Icons.download, size: 16, color: tr.error != null ? t.danger : (tr.finished ? t.accent : t.muted)),
                  const SizedBox(width: 8),
                  SizedBox(width: 180, child: Text(tr.name, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12, color: t.text))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: tr.error != null
                        ? Text(tr.error!, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.danger))
                        : LinearProgressIndicator(
                            value: tr.total == BigInt.zero ? null : (tr.done.toDouble() / tr.total.toDouble()).clamp(0, 1),
                            minHeight: 4,
                            color: t.accent,
                            backgroundColor: t.border,
                          ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    tr.error != null
                        ? 'Failed'
                        : tr.finished
                            ? 'Done · ${formatBytes(tr.done.toInt())}'
                            : '${formatBytes(tr.done.toInt())} of ${formatBytes(tr.total.toInt())}',
                    style: TextStyle(fontSize: 11, color: t.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
