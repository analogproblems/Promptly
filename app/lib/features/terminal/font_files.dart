import 'dart:io';
import 'dart:typed_data';

/// What a font file says about itself: its family, weight and slant, and
/// whether every character is the same width.
class FontFace {
  const FontFace({
    required this.family,
    required this.path,
    this.weight = 400,
    this.italic = false,
    this.monospaced = false,
  });

  final String family;
  final String path;
  final int weight;
  final bool italic;
  final bool monospaced;
}

/// Font files are named by extension; collections (`.ttc`) are read by
/// their first font, which is the one the text engine uses too.
bool isFontFileName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.ttf') || lower.endsWith('.otf') || lower.endsWith('.ttc') || lower.endsWith('.otc');
}

/// Read a font's name and style from its tables. `read` returns the bytes
/// at an offset, fewer at the end of the file. Null for anything that is
/// not a TrueType or OpenType font.
FontFace? parseFontFace(Uint8List Function(int offset, int length) read, String path) {
  try {
    var base = 0;
    if (_u32(read(0, 4), 0) == 0x74746366) {
      // 'ttcf': a collection; its first font.
      base = _u32(read(12, 4), 0);
    }
    final header = read(base, 12);
    final version = _u32(header, 0);
    if (version != 0x00010000 && version != 0x4F54544F && version != 0x74727565) return null;
    final count = ByteData.sublistView(header).getUint16(4);
    final records = ByteData.sublistView(read(base + 12, count * 16));
    final tables = <String, (int, int)>{};
    for (var i = 0; i < count; i++) {
      final at = i * 16;
      final tag = String.fromCharCodes([for (var j = 0; j < 4; j++) records.getUint8(at + j)]);
      tables[tag] = (records.getUint32(at + 8), records.getUint32(at + 12));
    }
    ByteData? table(String tag) {
      final t = tables[tag];
      return t == null ? null : ByteData.sublistView(read(t.$1, t.$2));
    }

    final names = table('name');
    if (names == null) return null;
    final family = _name(names, 16) ?? _name(names, 1);
    if (family == null || family.trim().isEmpty) return null;

    var weight = 400;
    var italic = false;
    var monospaced = false;
    final os2 = table('OS/2');
    if (os2 != null && os2.lengthInBytes >= 64) {
      weight = os2.getUint16(4);
      final selection = os2.getUint16(62);
      italic = selection & 0x0201 != 0; // italic or oblique
      // PANOSE: Latin text whose proportion is "monospaced".
      monospaced = os2.getUint8(32) == 2 && os2.getUint8(35) == 9;
    } else {
      final head = table('head');
      if (head != null && head.lengthInBytes >= 46) {
        final style = head.getUint16(44);
        if (style & 1 != 0) weight = 700;
        italic = style & 2 != 0;
      }
    }
    final post = table('post');
    if (post != null && post.lengthInBytes >= 16 && post.getUint32(12) != 0) monospaced = true;
    return FontFace(family: family.trim(), path: path, weight: weight, italic: italic, monospaced: monospaced);
  } catch (_) {
    return null;
  }
}

/// [parseFontFace] over a whole file in memory.
FontFace? parseFontBytes(Uint8List bytes, String path) => parseFontFace((offset, length) {
  final start = offset.clamp(0, bytes.length);
  return Uint8List.sublistView(bytes, start, (start + length).clamp(start, bytes.length));
}, path);

/// [parseFontFace] over a file on disk, reading only the parts it needs.
FontFace? parseFontFile(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final f = file;
    return parseFontFace((offset, length) {
      f.setPositionSync(offset);
      return f.readSync(length);
    }, path);
  } catch (_) {
    return null;
  } finally {
    file?.closeSync();
  }
}

int _u32(Uint8List bytes, int at) => ByteData.sublistView(bytes).getUint32(at);

/// A string from the `name` table, preferring US English from Windows
/// records, then any Unicode one, then the old Mac ones.
String? _name(ByteData table, int id) {
  final count = table.getUint16(2);
  final strings = table.getUint16(4);
  String? best;
  var bestScore = 0;
  for (var i = 0; i < count; i++) {
    final at = 6 + i * 12;
    if (table.getUint16(at + 6) != id) continue;
    final platform = table.getUint16(at);
    final encoding = table.getUint16(at + 2);
    final language = table.getUint16(at + 4);
    final length = table.getUint16(at + 8);
    final offset = strings + table.getUint16(at + 10);
    final score = switch (platform) {
      3 => language == 0x409 ? 4 : 3,
      0 => 2,
      1 when encoding == 0 && language == 0 => 1,
      _ => 0,
    };
    if (score <= bestScore) continue;
    final bytes = Uint8List.sublistView(table, offset, offset + length);
    if (platform == 1) {
      best = String.fromCharCodes(bytes);
    } else {
      final units = [for (var j = 0; j + 1 < bytes.length; j += 2) bytes[j] << 8 | bytes[j + 1]];
      best = String.fromCharCodes(units);
    }
    bestScore = score;
  }
  return best;
}

/// One family's files, the faces the terminal draws with first: regular,
/// bold, italic and bold italic, as far as the family has them.
class FontFamilyFiles {
  const FontFamilyFiles({required this.family, required this.paths, this.monospaced = true, this.added = false});

  final String family;
  final List<String> paths;
  final bool monospaced;

  /// A font the person added from a file, as opposed to one installed.
  final bool added;

  /// A Nerd Font, or another font of symbols: one to fall back on for the
  /// icons a prompt or editor draws.
  bool get hasSymbols {
    final name = family.toLowerCase();
    return name.contains('nerd font') || name.startsWith('symbols');
  }
}

/// Group faces into families, keeping the four faces the terminal uses.
/// Sorted by name.
List<FontFamilyFiles> groupFamilies(Iterable<FontFace> faces, {bool added = false}) {
  final byFamily = <String, List<FontFace>>{};
  for (final f in faces) {
    byFamily.putIfAbsent(f.family, () => []).add(f);
  }
  FontFace? closest(List<FontFace> faces, {required bool italic, required int weight, int? atLeast}) {
    FontFace? best;
    for (final f in faces) {
      if (f.italic != italic || (atLeast != null && f.weight < atLeast)) continue;
      if (best == null || (f.weight - weight).abs() < (best.weight - weight).abs()) best = f;
    }
    return best;
  }

  final families = [
    for (final MapEntry(key: family, value: list) in byFamily.entries)
      FontFamilyFiles(
        family: family,
        paths: {
          for (final f in [
            closest(list, italic: false, weight: 400) ?? list.first,
            closest(list, italic: false, weight: 700, atLeast: 600),
            closest(list, italic: true, weight: 400),
            closest(list, italic: true, weight: 700, atLeast: 600),
          ])
            ?f?.path,
        }.toList(),
        monospaced: list.any((f) => f.monospaced),
        added: added,
      ),
  ];
  return families..sort((a, b) => a.family.toLowerCase().compareTo(b.family.toLowerCase()));
}

/// Where this system keeps its fonts.
List<String> systemFontFolders() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  if (Platform.isLinux) {
    final data = (env['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share').split(':');
    return {
      for (final d in data)
        if (d.isNotEmpty) '$d/fonts',
      '/usr/share/fonts',
      '/usr/local/share/fonts',
      '${env['XDG_DATA_HOME'] ?? '$home/.local/share'}/fonts',
      '$home/.fonts',
    }.toList();
  }
  if (Platform.isMacOS) return ['/System/Library/Fonts', '/Library/Fonts', '$home/Library/Fonts'];
  if (Platform.isWindows) {
    final local = env['LOCALAPPDATA'];
    return ['${env['WINDIR'] ?? r'C:\Windows'}\\Fonts', if (local != null) '$local\\Microsoft\\Windows\\Fonts'];
  }
  if (Platform.isAndroid) return ['/system/fonts', '/product/fonts'];
  return const [];
}

/// The monospaced font families in [folders] and the folders inside them.
/// Slow on a system with many fonts: run it off the main isolate.
List<FontFamilyFiles> scanMonospacedFonts(List<String> folders, {int limit = 5000}) {
  final faces = <FontFace>[];
  var seen = 0;
  for (final folder in folders) {
    final dir = Directory(folder);
    if (!dir.existsSync()) continue;
    try {
      for (final entry in dir.listSync(recursive: true, followLinks: false)) {
        if (entry is! File || !isFontFileName(entry.path)) continue;
        if (++seen > limit) break;
        final face = parseFontFile(entry.path);
        // Emoji fonts call themselves fixed-pitch too, but are no use for text.
        if (face != null && face.monospaced && !face.family.toLowerCase().contains('emoji')) faces.add(face);
      }
    } catch (_) {
      // A folder we may not read: the others still count.
    }
  }
  return groupFamilies(faces);
}
