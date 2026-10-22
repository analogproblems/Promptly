import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/features/updates/updates.dart';

void main() {
  test('versions compare by number, not by text', () {
    expect(isNewer('1.0.10', '1.0.9'), isTrue);
    expect(isNewer('v2.0.0', '1.9.9'), isTrue);
    expect(isNewer('1.0.1', '1.0.1'), isFalse);
    expect(isNewer('1.0.0', '1.0.1'), isFalse);
    expect(isNewer('1.1.0-beta', '1.0.1'), isFalse, reason: 'not a plain version');
  });

  test('a GitHub release reads its version and the file each kind of install updates from', () {
    final r = Release.fromGitHub({
      'tag_name': 'v1.2.3',
      'html_url': 'https://github.com/analogproblems/Promptly/releases/tag/v1.2.3',
      'assets': [
        {'name': 'promptly-1.2.3-windows-x64.zip', 'browser_download_url': 'https://z', 'size': 10},
        {
          'name': 'promptly-1.2.3-windows-x64-setup.exe',
          'browser_download_url': 'https://s',
          'size': 20,
          'digest': 'sha256:ABC123',
        },
        {'name': 'promptly-1.2.3-linux-x64.tar.gz', 'browser_download_url': 'https://t', 'size': 30},
        {'name': 'promptly_1.2.3_amd64.deb', 'browser_download_url': 'https://d', 'size': 40},
        {'name': 'promptly-1.2.3-macos.dmg', 'browser_download_url': 'https://m', 'size': 50},
      ],
    })!;
    expect(r.version, '1.2.3');
    expect(r.pageUrl, endsWith('/v1.2.3'));
    final installer = r.assetFor(InstallKind.windowsInstaller)!;
    expect(installer.url, 'https://s');
    expect(installer.size, 20);
    expect(installer.sha256, 'abc123');
    expect(r.assetFor(InstallKind.windowsZip)!.url, 'https://s', reason: 'the zip moves to the installer');
    expect(r.assetFor(InstallKind.linuxTarball)!.url, 'https://t');
    expect(r.assetFor(InstallKind.linuxDeb)!.url, 'https://d');
    expect(r.assetFor(InstallKind.manual), isNull);
  });

  test('a release without the files, or without a version tag', () {
    final bare = Release.fromGitHub({'tag_name': 'v1.0.2', 'assets': []})!;
    for (final kind in InstallKind.values) {
      expect(bare.assetFor(kind), isNull);
    }
    expect(Release.fromGitHub({'tag_name': 'nightly'}), isNull);
    expect(Release.fromGitHub('nonsense'), isNull);
  });

  group('swapping in a new tarball', () {
    late Directory root, dir;
    setUp(() {
      root = Directory.systemTemp.createTempSync('promptly-swap');
      dir = Directory('${root.path}/promptly-1.0.0-linux-x64')..createSync();
      File('${dir.path}/promptly').writeAsStringSync('old');
    });
    tearDown(() => root.deleteSync(recursive: true));

    File tarball(Map<String, String> files) {
      final src = Directory('${root.path}/src')..createSync();
      files.forEach((path, text) => File('${src.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(text));
      final out = File('${root.path}/new.tar.gz');
      final r = Process.runSync('tar', ['-czf', out.path, '-C', src.path, ...files.keys.map((p) => p.split('/').first).toSet()]);
      expect(r.exitCode, 0);
      src.deleteSync(recursive: true);
      return out;
    }

    // Folders of the person's own beside the app, with names an update
    // might have picked.
    void neighbours() {
      for (final name in ['.old', '.update', '.bak']) {
        File('${dir.path}$name/keep')
          ..createSync(recursive: true)
          ..writeAsStringSync('mine');
      }
    }

    List<String> beside() => [for (final e in root.listSync()) e.path.split('/').last]..sort();

    void neighboursKept() {
      for (final name in ['.old', '.update', '.bak']) {
        expect(File('${dir.path}$name/keep').readAsStringSync(), 'mine');
      }
    }

    test('the new version takes the folder\'s place and name', () async {
      neighbours();
      final src = tarball({'promptly-2.0.0-linux-x64/promptly': 'new'});
      final work = await const UpdateService().swapFolder(src, dir);
      expect(File('${dir.path}/promptly').readAsStringSync(), 'new');
      expect(File('${work.path}/old/promptly').readAsStringSync(), 'old', reason: 'removed once this copy quits');
      expect(work.parent.path, root.path);
      neighboursKept();
    });

    test('a tarball without the app leaves the folder and its neighbours alone', () async {
      neighbours();
      final src = tarball({'something-else/readme': 'x'});
      final before = beside();
      await expectLater(const UpdateService().swapFolder(src, dir), throwsA(isA<UpdateError>()));
      expect(File('${dir.path}/promptly').readAsStringSync(), 'old');
      neighboursKept();
      expect(beside(), before, reason: 'its own work folder is gone again');
    });

    test('each download gets a new folder only this user can change', () async {
      final a = await const UpdateService().downloadFolder();
      final b = await const UpdateService().downloadFolder();
      addTearDown(() {
        a.deleteSync();
        b.deleteSync();
      });
      expect(a.path, isNot(b.path));
      if (!Platform.isWindows) {
        expect(a.statSync().mode & 0x12, 0, reason: 'no writing for the group or anyone else');
      }
    });
  });
}
