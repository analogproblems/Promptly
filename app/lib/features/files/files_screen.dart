import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/models.dart' show relativeTime;
import '../sessions/session_manager.dart';
import '../shell/empty_state.dart';
import '../shell/shell_scaffold.dart';
import 'device_files.dart';
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

  /// Downloads to hand on once they finish, by transfer id: the file to
  /// share or open.
  final Map<int, ({_Then then, String path})> _after = {};

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
    for (final t in now) {
      if (!t.finished) continue;
      final next = _after.remove(t.id);
      if (next != null && !t.cancelled && t.error == null) _handOn(next.then, next.path);
    }
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Folders cannot be copied yet; open one and copy its files.')));
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

  void _say(Object message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message is String ? message : '$message')));
  }

  /// Start a copy the engine runs, reporting a refusal instead of throwing.
  int? _start(int Function(Engine engine, int browser) copy) {
    final id = _browserId;
    if (id == null) return null;
    try {
      final tid = copy(ref.read(engineProvider), id);
      _watchTransfers();
      return tid;
    } catch (e) {
      _say(e);
      return null;
    }
  }

  /// Where the share sheet points from on a tablet: this screen.
  Rect? _origin() {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  }

  /// One pane only (a phone): pick files on this device and upload them
  /// into the server folder on show.
  Future<void> _upload() async {
    final pane = _remotePane.currentState;
    final dir = pane?.path;
    if (dir == null) return;
    final List<PickedFile> picked;
    try {
      picked = await ref.read(deviceFilesProvider).pick();
    } catch (e) {
      _say(e);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    final there = {for (final e in pane!._entries) e.name};
    final clash = [for (final f in picked) if (there.contains(f.name)) f.name];
    if (clash.isNotEmpty && !await _confirmReplace(clash)) return;
    for (final f in picked) {
      _start((engine, id) => engine.filesUpload(id, f.path, _remote!.join(dir, f.name)));
    }
  }

  Future<bool> _confirmReplace(List<String> names) async {
    final one = names.length == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(one ? 'Replace ${names.first}?' : 'Replace ${names.length} files?'),
        content: Text(
          one
              ? 'This folder on the server already has a file with that name. Uploading replaces it.'
              : 'This folder on the server already has files with these names: ${names.join(', ')}. Uploading replaces them.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('files-replace-ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// One pane only: save a server file on this device. A computer asks
  /// where; a phone fetches it, then offers the share sheet to save or send.
  Future<void> _download(FsEntry e) async {
    final device = ref.read(deviceFilesProvider);
    if (!device.savesWithDialog) return _downloadThen(e, _Then.share);
    final String? path;
    try {
      path = await device.saveLocation(e.name);
    } catch (err) {
      _say(err);
      return;
    }
    if (path == null || !mounted) return;
    _start((engine, id) => engine.filesDownload(id, e.path, path!));
  }

  /// Fetch a server file to this device's cache, then share or open it.
  Future<void> _downloadThen(FsEntry e, _Then then) async {
    final String path;
    try {
      path = await ref.read(deviceFilesProvider).scratchPath(e.name);
    } catch (err) {
      _say(err);
      return;
    }
    if (!mounted) return;
    final tid = _start((engine, id) => engine.filesDownload(id, e.path, path));
    if (tid == null) return;
    _after[tid] = (then: then, path: path);
    // It may have finished already.
    _refreshTransfers();
  }

  Future<void> _handOn(_Then then, String path) async {
    final device = ref.read(deviceFilesProvider);
    try {
      switch (then) {
        case _Then.share:
          await device.share(path, origin: _origin());
        case _Then.open:
          await device.open(path, origin: _origin());
      }
    } catch (e) {
      _say(e);
    }
  }

  void _cancel(int transfer) {
    final id = _browserId;
    if (id == null) return;
    _after.remove(transfer);
    try {
      ref.read(engineProvider).filesCancelTransfer(id, transfer);
    } catch (e) {
      _say(e);
    }
    _refreshTransfers();
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
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.danger),
          ),
        ),
      );
    } else if (_remote == null) {
      body = Center(
        child: Text('Opening the file browser…', style: TextStyle(color: t.muted)),
      );
    } else {
      // One pane: the device's side of a copy is the system picker, a save
      // dialog or the share sheet instead of a second list.
      final remotePane = _FsPane(
        key: _remotePane,
        fs: _remote!,
        startDir: null,
        onTransfer: desktop ? (e) => transfer(e, fromRemote: true) : _download,
        onUpload: desktop ? null : _upload,
        onOpenElsewhere: (e) => _downloadThen(e, _Then.open),
        onDropped: desktop
            ? (d) {
                if (!d.remote) transfer(d.entry, fromRemote: false);
              }
            : null,
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
          decoration: BoxDecoration(
            color: t.surface,
            border: Border(bottom: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to the session',
                onPressed: () => context.go('/sessions/${widget.sessionId}'),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text),
                ),
              ),
              if (desktop)
                Text('Drag files between the two sides to copy them.', style: TextStyle(fontSize: 12, color: t.muted)),
            ],
          ),
        ),
        Expanded(child: body),
        if (_transfers.isNotEmpty)
          _TransfersBar(
            transfers: _transfers,
            onCancel: _cancel,
            onClear: () {
              final id = _browserId;
              if (id != null) ref.read(engineProvider).filesClearTransfers(id);
              _refreshTransfers();
            },
          ),
      ],
    );
  }
}

/// What to do with a download once it is on this device.
enum _Then { share, open }

/// One folder listing with its path, toolbar and entry menus.
class _FsPane extends StatefulWidget {
  const _FsPane({
    super.key,
    required this.fs,
    required this.startDir,
    this.onTransfer,
    this.onDropped,
    this.onUpload,
    this.onOpenElsewhere,
  });

  final Fs fs;
  final String? startDir;

  /// "Copy to the other side": the other pane, or this device on a phone.
  final void Function(FsEntry entry)? onTransfer;

  /// Files dropped from the other pane; also makes the rows draggable.
  final void Function(FsDrag drag)? onDropped;

  /// Upload files picked on this device into the folder on show.
  final VoidCallback? onUpload;

  /// Hand a file to whichever app on this device opens it.
  final void Function(FsEntry entry)? onOpenElsewhere;

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

  /// Open a file in the editor; saving writes it back where it is.
  Future<void> _edit(FsEntry e) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TextEditorDialog(fs: widget.fs, entry: e),
    );
    if (changed == true) await refresh();
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
        content: Text(
          e.isDir ? 'The folder and everything in it are removed. This cannot be undone.' : 'This cannot be undone.',
        ),
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
    final mode = await showDialog<int>(
      context: context,
      builder: (_) => _PermissionsDialog(name: e.name, mode: e.permissions),
    );
    if (mode == null || mode == e.permissions & 0xFFF) return;
    await _run(() => widget.fs.chmod(e.path, mode));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = path;
    final crumbs = p == null ? const <({String label, String path})>[] : widget.fs.crumbs(p);
    final remote = widget.fs.isRemote;
    final side = remote ? 'remote' : 'local';

    Widget list;
    if (_error != null) {
      list = Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.danger, fontSize: 13),
          ),
        ),
      );
    } else if (_loading && _entries.isEmpty) {
      list = Center(
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: t.muted)),
      );
    } else if (_entries.isEmpty) {
      list = Center(
        child: Text('Empty folder', style: TextStyle(color: t.muted, fontSize: 13)),
      );
    } else {
      list = ListView.builder(
        itemCount: _entries.length,
        itemBuilder: (context, i) {
          final e = _entries[i];
          final row = _EntryRow(
            key: Key('$side-entry-${e.name}'),
            entry: e,
            onOpen: e.isDir ? () => go(e.path) : () => _edit(e),
            onAction: (action) {
              switch (action) {
                case 'open':
                  if (e.isDir) go(e.path);
                case 'edit':
                  _edit(e);
                case 'copy':
                  widget.onTransfer?.call(e);
                case 'open-elsewhere':
                  widget.onOpenElsewhere?.call(e);
                case 'rename':
                  _rename(e);
                case 'delete':
                  _delete(e);
                case 'permissions':
                  _permissions(e);
              }
            },
            canCopy: widget.onTransfer != null,
            canOpenElsewhere: widget.onOpenElsewhere != null,
            copyLabel: remote ? 'Download to this device' : 'Upload to the server',
          );
          if (widget.onDropped == null) return row;
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
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              Text(
                widget.fs.label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: t.muted),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      for (var i = 0; i < crumbs.length; i++) ...[
                        if (i > 0) Text('›', style: TextStyle(color: t.muted)),
                        _Crumb(
                          label: crumbs[i].label,
                          onTap: () => go(crumbs[i].path),
                          last: i > 0 && i == crumbs.length - 1,
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
                onPressed: p == null || widget.fs.isRoot(p) ? null : () => go(widget.fs.parent(p)),
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              IconButton(
                key: Key('$side-refresh'),
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                onPressed: refresh,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              if (widget.onUpload != null)
                IconButton(
                  key: Key('$side-upload'),
                  tooltip: 'Upload files from this device',
                  visualDensity: VisualDensity.compact,
                  onPressed: p == null ? null : widget.onUpload,
                  icon: const Icon(Icons.upload_file, size: 18),
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
        child: Text(
          label,
          style: monoStyle(
            context,
            size: 12,
            weight: last ? FontWeight.w600 : FontWeight.w400,
            color: last ? t.text : t.muted,
          ),
        ),
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
    required this.canOpenElsewhere,
    required this.copyLabel,
  });

  final FsEntry entry;
  final VoidCallback? onOpen;
  final void Function(String action) onAction;
  final bool canCopy;
  final bool canOpenElsewhere;
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
              child: Text(
                e.name,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(context, size: 13, color: t.text),
              ),
            ),
            if (!e.isDir)
              SizedBox(
                width: 72,
                child: Text(
                  formatBytes(e.size),
                  textAlign: TextAlign.right,
                  style: monoStyle(context, size: 11, color: t.muted),
                ),
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
                if (!e.isDir) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (canCopy && !e.isDir) PopupMenuItem(value: 'copy', child: Text(copyLabel)),
                if (canOpenElsewhere && !e.isDir)
                  const PopupMenuItem(value: 'open-elsewhere', child: Text('Open in another app')),
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
  // The permission bits, with setuid, setgid and sticky kept as they are.
  late int _mode = widget.mode & 0xFFF;

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
                SizedBox(
                  width: 64,
                  child: Text(who[w], style: TextStyle(color: t.text)),
                ),
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
          Text(
            '${formatMode(_mode)}  ${_mode.toRadixString(8).padLeft(3, '0')}',
            style: monoStyle(context, size: 13, color: t.muted),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('perm-apply'),
          onPressed: () => Navigator.pop(context, _mode),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _TransfersBar extends StatelessWidget {
  const _TransfersBar({required this.transfers, required this.onClear, required this.onCancel});

  final List<FileTransfer> transfers;
  final VoidCallback onClear;
  final void Function(int transfer) onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shown = transfers.reversed.take(4).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A Wrap, so the button drops below the heading with large text.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Transfers',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: t.muted),
              ),
              TextButton(onPressed: onClear, child: const Text('Clear finished')),
            ],
          ),
          for (final tr in shown) _TransferRow(key: Key('transfer-${tr.id}'), transfer: tr, onCancel: onCancel),
        ],
      ),
    );
  }
}

/// One copy: its name and state on a line, the progress under it, and a
/// cancel button while it runs. Two lines rather than one, so it fits a
/// phone at large text.
class _TransferRow extends StatelessWidget {
  const _TransferRow({super.key, required this.transfer, required this.onCancel});

  final FileTransfer transfer;
  final void Function(int transfer) onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tr = transfer;
    final status = tr.cancelled
        ? 'Cancelled'
        : tr.error != null
        ? 'Failed'
        : tr.finished
        ? 'Done · ${formatBytes(tr.done.toInt())}'
        : '${formatBytes(tr.done.toInt())} of ${formatBytes(tr.total.toInt())}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            tr.upload ? Icons.upload : Icons.download,
            size: 16,
            color: tr.error != null ? t.danger : (tr.finished && !tr.cancelled ? t.accent : t.muted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr.name,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(context, size: 12, color: t.text),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        status,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: t.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                if (tr.error != null && !tr.cancelled)
                  Text(
                    tr.error!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.danger),
                  )
                else if (!tr.cancelled)
                  LinearProgressIndicator(
                    value: tr.total == BigInt.zero ? null : (tr.done.toDouble() / tr.total.toDouble()).clamp(0, 1),
                    minHeight: 4,
                    color: t.accent,
                    backgroundColor: t.border,
                  ),
              ],
            ),
          ),
          if (!tr.finished)
            IconButton(
              key: Key('transfer-cancel-${tr.id}'),
              tooltip: 'Cancel ${tr.upload ? 'upload' : 'download'} of ${tr.name}',
              visualDensity: VisualDensity.compact,
              onPressed: () => onCancel(tr.id),
              icon: const Icon(Icons.close, size: 18),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// A plain text editor over one file, remote or local: load, edit, save
/// in place. Ctrl+S saves; closing with changes asks first.
class TextEditorDialog extends StatefulWidget {
  const TextEditorDialog({super.key, required this.fs, required this.entry});

  final Fs fs;
  final FsEntry entry;

  @override
  State<TextEditorDialog> createState() => _TextEditorDialogState();
}

class _TextEditorDialogState extends State<TextEditorDialog> {
  final _controller = TextEditingController();
  String? _loaded;
  String? _error;
  bool _saving = false;
  bool _savedOnce = false;

  bool get _dirty => _loaded != null && _controller.text != _loaded;

  @override
  void initState() {
    super.initState();
    _load();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = await widget.fs.readText(widget.entry.path);
      if (!mounted) return;
      setState(() {
        _loaded = text;
        _controller.text = text;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is String ? e : e.toString());
    }
  }

  Future<void> _save() async {
    if (_loaded == null || _saving) return;
    setState(() => _saving = true);
    // What is written is what counts as saved: typing carries on meanwhile.
    final text = _controller.text;
    try {
      await widget.fs.writeText(widget.entry.path, text);
      if (!mounted) return;
      setState(() {
        _loaded = text;
        _saving = false;
        _savedOnce = true;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${widget.entry.name}')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is String ? e : e.toString();
      });
    }
  }

  Future<void> _close() async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Close ${widget.entry.name} without saving?'),
          content: const Text('The changes made here are lost.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
            FilledButton(
              key: const Key('editor-discard'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context, _savedOnce);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyS &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
      _save();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final lines = _loaded == null ? 0 : '\n'.allMatches(_controller.text).length + 1;
    return PopScope(
      // System Back asks first too, as the close button does.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Dialog.fullscreen(
        child: Focus(
          onKeyEvent: _onKey,
          // Its own messenger, so "Saved" shows here and not on the screen behind.
          child: ScaffoldMessenger(
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  key: const Key('editor-close'),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: _close,
                ),
                title: Row(
                  children: [
                    Flexible(child: Text(widget.entry.name, overflow: TextOverflow.ellipsis)),
                    if (_dirty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('edited', style: TextStyle(fontSize: 12, color: t.warning)),
                      ),
                  ],
                ),
                actions: [
                  if (_loaded != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Center(
                        child: Text(
                          '$lines line${lines == 1 ? '' : 's'} · ${widget.fs.label}',
                          style: TextStyle(fontSize: 12, color: t.muted),
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    key: const Key('editor-save'),
                    onPressed: _loaded == null || _saving || !_dirty ? null : _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
              body: _error != null && _loaded == null
                  ? EmptyState(icon: Icons.description_outlined, title: 'Cannot edit this file', message: _error!)
                  : _loaded == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        if (_error != null)
                          Container(
                            width: double.infinity,
                            color: t.danger.withValues(alpha: 0.12),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Text(_error!, style: TextStyle(color: t.danger, fontSize: 13)),
                          ),
                        Expanded(
                          child: TextField(
                            key: const Key('editor-text'),
                            controller: _controller,
                            autofocus: true,
                            maxLines: null,
                            expands: true,
                            keyboardType: TextInputType.multiline,
                            textAlignVertical: TextAlignVertical.top,
                            style: monoStyle(context, size: 13, color: t.text),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.all(16),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
