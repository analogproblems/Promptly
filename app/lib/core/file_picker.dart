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
