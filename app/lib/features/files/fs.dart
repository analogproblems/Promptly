import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import '../../core/engine/engine.dart';

/// One file or folder, wherever it lives.
class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.isSymlink = false,
    this.size = 0,
    this.modified,
    this.permissions = 0,
  });

  final String name;
  final String path;
  final bool isDir;
  final bool isSymlink;
  final int size;
  final DateTime? modified;

  /// The permission bits, as in `chmod`; 0 when unknown.
  final int permissions;
}

/// A folder tree with the handful of operations the browser needs. The
/// remote one talks to the engine; the local one to the disk.
abstract class Fs {
  /// "Server" or "This device", for headings and messages.
  String get label;

  bool get isRemote;

  Future<String> home();

  Future<List<FsEntry>> list(String dir);

  Future<void> mkdir(String path);

  Future<void> rename(String from, String to);

  Future<void> delete(String path);

  Future<void> chmod(String path, int mode);

  /// A text file's contents, for the editor. Throws for binary or very
  /// large files, with a message the person can act on.
  Future<String> readText(String path);

  Future<void> writeText(String path, String text);

  String join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  String parent(String path) {
    final trimmed = path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final i = trimmed.lastIndexOf('/');
    if (i <= 0) return '/';
    return trimmed.substring(0, i);
  }

  /// The folders from the root down to `path`, for the breadcrumbs.
  List<({String label, String path})> crumbs(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    return [
      (label: '/', path: '/'),
      for (var i = 0; i < segments.length; i++) (label: segments[i], path: '/${segments.sublist(0, i + 1).join('/')}'),
    ];
  }

  bool isRoot(String path) => parent(path) == path;
}

/// The server's files, over the session's SFTP browser.
class RemoteFs extends Fs {
  RemoteFs(this.engine, this.browserId);

  final Engine engine;
  final int browserId;

  @override
  String get label => 'Server';

  @override
  bool get isRemote => true;

  @override
  Future<String> home() => engine.filesHome(browserId);

  @override
  Future<List<FsEntry>> list(String dir) async {
    final entries = await engine.filesList(browserId, dir);
    return [
      for (final e in entries)
        FsEntry(
          name: e.name,
          path: join(dir, e.name),
          isDir: e.isDir,
          isSymlink: e.isSymlink,
          size: e.size.toInt(),
          modified: e.modified == BigInt.zero ? null : DateTime.fromMillisecondsSinceEpoch(e.modified.toInt() * 1000),
          permissions: e.permissions,
        ),
    ];
  }

  @override
  Future<void> mkdir(String path) => engine.filesMkdir(browserId, path);

  @override
  Future<void> rename(String from, String to) => engine.filesRename(browserId, from, to);

  @override
  Future<void> delete(String path) => engine.filesDelete(browserId, path);

  @override
  Future<void> chmod(String path, int mode) => engine.filesChmod(browserId, path, mode);

  @override
  Future<String> readText(String path) => engine.filesReadText(browserId, path);

  @override
  Future<void> writeText(String path, String text) => engine.filesWriteText(browserId, path, text);
}

/// This device's files.
class LocalFs extends Fs {
  LocalFs({bool? windows}) : windows = windows ?? io.Platform.isWindows;

  /// Paths like `C:\Users\me` or `\\server\share\dir` rather than POSIX ones.
  final bool windows;

  /// The root a Windows path sits under (`C:\`, `\\server\share\`), or ''.
  String _root(String path) {
    final drive = RegExp(r'^[A-Za-z]:[\\/]?').firstMatch(path);
    if (drive != null) return '${path.substring(0, 2)}\\';
    final unc = RegExp(r'^[\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]?').firstMatch(path);
    if (unc != null) return '${unc.group(0)!.replaceAll('/', '\\').replaceFirst(RegExp(r'\\?$'), '')}\\';
    return '';
  }

  List<String> _segments(String path, String root) =>
      path.substring(math.min(root.length, path.length)).split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();

  @override
  String join(String dir, String name) {
    if (!windows) return super.join(dir, name);
    return dir.endsWith('\\') || dir.endsWith('/') ? '$dir$name' : '$dir\\$name';
  }

  @override
  String parent(String path) {
    if (!windows) return super.parent(path);
    final root = _root(path);
    final segments = _segments(path, root);
    if (segments.isEmpty) return root.isEmpty ? path : root;
    return root + segments.sublist(0, segments.length - 1).join('\\');
  }

  @override
  List<({String label, String path})> crumbs(String path) {
    if (!windows) return super.crumbs(path);
    final root = _root(path);
    final segments = _segments(path, root);
    return [
      if (root.isNotEmpty) (label: root, path: root),
      for (var i = 0; i < segments.length; i++)
        (label: segments[i], path: root + segments.sublist(0, i + 1).join('\\')),
    ];
  }

  @override
  String get label => 'This device';

  @override
  bool get isRemote => false;

  @override
  Future<String> home() async =>
      io.Platform.environment['HOME'] ?? io.Platform.environment['USERPROFILE'] ?? io.Directory.current.path;

  @override
  Future<List<FsEntry>> list(String dir) async {
    final out = <FsEntry>[];
    await for (final e in io.Directory(dir).list(followLinks: false)) {
      final stat = await e.stat();
      final link = e is io.Link;
      var isDir = e is io.Directory;
      if (link) {
        try {
          isDir = await io.FileSystemEntity.isDirectory(e.path);
        } catch (_) {}
      }
      out.add(
        FsEntry(
          name: e.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? e.path,
          path: e.path,
          isDir: isDir,
          isSymlink: link,
          size: stat.size,
          modified: stat.modified,
          permissions: stat.mode & 0xFFF,
        ),
      );
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Future<void> mkdir(String path) => io.Directory(path).create();

  @override
  Future<void> rename(String from, String to) async {
    if (await io.FileSystemEntity.isDirectory(from)) {
      await io.Directory(from).rename(to);
    } else {
      await io.File(from).rename(to);
    }
  }

  @override
  Future<void> delete(String path) async {
    if (await io.FileSystemEntity.isDirectory(path)) {
      await io.Directory(path).delete(recursive: true);
    } else {
      await io.File(path).delete();
    }
  }

  @override
  Future<void> chmod(String path, int mode) async {
    if (io.Platform.isWindows) return;
    final result = await io.Process.run('chmod', [mode.toRadixString(8), path]);
    if (result.exitCode != 0) throw (result.stderr as String).trim();
  }

  static const maxEditBytes = 2 * 1024 * 1024;

  @override
  Future<String> readText(String path) async {
    final file = io.File(path);
    final size = await file.length();
    if (size > maxEditBytes) throw 'too large to edit here ($size bytes)';
    final bytes = await file.readAsBytes();
    if (bytes.contains(0)) throw 'not a text file';
    try {
      return const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      throw 'not UTF-8 text';
    }
  }

  @override
  Future<void> writeText(String path, String text) => io.File(path).writeAsString(text);
}

/// "1.2 MB", "340 KB", "12 B".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value < 10 ? value.toStringAsFixed(1) : value.round()} ${units[unit]}';
}

/// "rwxr-x---" for a mode.
String formatMode(int mode) {
  const bits = ['r', 'w', 'x'];
  final out = StringBuffer();
  for (var i = 8; i >= 0; i--) {
    out.write((mode >> i) & 1 == 1 ? bits[(8 - i) % 3] : '-');
  }
  return out.toString();
}
