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

  test('a GitHub release reads its version and the Windows installer', () {
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
      ],
    })!;
    expect(r.version, '1.2.3');
    expect(r.pageUrl, endsWith('/v1.2.3'));
    expect(r.windowsInstaller!.url, 'https://s');
    expect(r.windowsInstaller!.size, 20);
    expect(r.windowsInstaller!.sha256, 'abc123');
  });

  test('a release without an installer, or without a version tag', () {
    expect(Release.fromGitHub({'tag_name': 'v1.0.2', 'assets': []})!.windowsInstaller, isNull);
    expect(Release.fromGitHub({'tag_name': 'nightly'}), isNull);
    expect(Release.fromGitHub('nonsense'), isNull);
  });
}
