import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/file_picker.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('promptly-save-'));
  tearDown(() => dir.deleteSync(recursive: true));

  int mode(String path) => File(path).statSync().mode & 0x1ff;

  test('a saved file is owner-only, even over one others could read', () async {
    final path = '${dir.path}/id_ed25519';
    File(path).writeAsStringSync('old');
    await Process.run('chmod', ['644', path]);

    await writeOwnerOnly(path, 'secret');

    expect(File(path).readAsStringSync(), 'secret');
    expect(mode(path), 0x180, reason: '0600');
    expect(dir.listSync(), hasLength(1), reason: 'nothing left beside it');
  }, skip: Platform.isWindows);

  test('when owner-only cannot be set, nothing is written', () async {
    final path = '${dir.path}/id_ed25519';
    File(path).writeAsStringSync('old');

    Future<ProcessResult> failing(String _, List<String> _) async =>
        ProcessResult(0, 1, '', 'Operation not permitted');
    await expectLater(writeOwnerOnly(path, 'secret', run: failing), throwsA(isA<FileSystemException>()));

    expect(File(path).readAsStringSync(), 'old');
    expect(dir.listSync(), hasLength(1), reason: 'the new file is removed');

    Future<ProcessResult> throwing(String _, List<String> _) => throw const ProcessException('chmod', []);
    await expectLater(writeOwnerOnly(path, 'secret', run: throwing), throwsA(isA<ProcessException>()));
    expect(File(path).readAsStringSync(), 'old');
    expect(dir.listSync(), hasLength(1));
  }, skip: Platform.isWindows);
}
