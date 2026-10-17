import 'dart:io' show File, FileSystemException, Platform, Process, ProcessResult;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A text file the person chose: its name and its contents.
class PickedTextFile {
  const PickedTextFile({required this.name, required this.text});

  final String name;
  final String text;
}

/// Ask for a file. `extensions` narrows the picker where the platform
/// supports it; `label` names the kind of file in the picker.
typedef PickTextFile = Future<PickedTextFile?> Function({required String label, required List<String> extensions});

Future<PickedTextFile?> _pickWithPlatform({required String label, required List<String> extensions}) async {
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(label: label, extensions: extensions),
      const XTypeGroup(label: 'All files'),
    ],
  );
  if (file == null) return null;
  return PickedTextFile(name: file.name, text: await file.readAsString());
}

/// The file picker, swapped for a fake in tests.
final filePickerProvider = Provider<PickTextFile>((ref) => _pickWithPlatform);

/// Ask where to save a text file and write it there, readable only by its
/// owner where the system has such modes. Returns the path, or null when
/// the person cancelled. Null as a whole where the platform has no save
/// dialog (phones).
typedef SaveTextFile = Future<String?> Function({required String suggestedName, required String text});

Future<String?> _saveWithPlatform({required String suggestedName, required String text}) async {
  final location = await getSaveLocation(suggestedName: suggestedName);
  if (location == null) return null;
  await writeOwnerOnly(location.path, text);
  return location.path;
}

/// Write `text` to `path` readable only by its owner, where the system has
/// such modes. A new file beside it is made owner-only before the text goes
/// in, then put in its place, so an existing file's wider mode does not
/// carry over. If owner-only can't be set, nothing is written and it throws.
Future<void> writeOwnerOnly(
  String path,
  String text, {
  Future<ProcessResult> Function(String, List<String>) run = Process.run,
}) async {
  if (Platform.isWindows) {
    await File(path).writeAsString(text, flush: true);
    return;
  }
  final temp = File('$path.promptly-new');
  await temp.writeAsString('');
  try {
    final chmod = await run('chmod', ['600', temp.path]);
    if (chmod.exitCode != 0) {
      throw FileSystemException('could not make the file readable only by you: ${chmod.stderr}'.trim(), path);
    }
    await temp.writeAsString(text, flush: true);
    await temp.rename(path);
  } catch (_) {
    try {
      await temp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// The save dialog, swapped for a fake in tests.
final fileSaverProvider = Provider<SaveTextFile?>(
  (ref) => Platform.isAndroid || Platform.isIOS ? null : _saveWithPlatform,
);
