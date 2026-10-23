import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/links.dart';
import '../../core/theme/tokens.dart';
import 'updates.dart';

/// The About page's update row: check now, and when a new version is out,
/// install it (Windows, Linux, and Android from the GitHub APK) or open its
/// download page.
class UpdatePanel extends ConsumerWidget {
  const UpdatePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final state = ref.watch(updateProvider);
    final notifier = ref.read(updateProvider.notifier);

    Widget checkButton() => TextButton(
      key: const Key('update-check-now'),
      onPressed: notifier.check,
      child: const Text('Check'),
    );

    Widget openPage(Release r) => TextButton(
      key: const Key('update-open-page'),
      onPressed: () => openExternalLink(r.pageUrl),
      child: const Text('Download'),
    );

    final (IconData icon, String title, String subtitle, Widget? trailing) = switch (state) {
      UpdateIdle() => (Icons.update, 'Check for updates', 'Looks for a newer version on GitHub.', checkButton()),
      UpdateChecking() => (
        Icons.update,
        'Checking for updates',
        'Asking GitHub for the newest version.',
        const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      UpdateUpToDate() => (Icons.check_circle_outline, 'Promptly is up to date', 'This is the newest version.', checkButton()),
      UpdateAvailable(:final release) when state.canInstallInApp => (
        Icons.system_update_alt,
        'Version ${release.version} is out',
        _installHint,
        FilledButton(
          key: const Key('update-install'),
          onPressed: () => notifier.installAndRestart(release),
          child: Text(switch (installKind) {
            InstallKind.windowsZip => 'Install and restart',
            InstallKind.androidApk => 'Update',
            _ => 'Update and restart',
          }),
        ),
      ),
      UpdateAvailable(:final release) => (
        Icons.system_update_alt,
        'Version ${release.version} is out',
        _downloadHint,
        openPage(release),
      ),
      UpdateDownloading(:final release, :final progress) => (
        Icons.downloading,
        'Downloading ${release.version}',
        '${(progress * 100).round()}%',
        SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, value: progress)),
      ),
      UpdateInstalling(:final release) => (
        Icons.system_update_alt,
        'Installing ${release.version}',
        switch (installKind) {
          InstallKind.linuxDeb => 'Enter your password to install it. Promptly then closes and opens again.',
          InstallKind.androidApk => 'Confirm on the screen Android shows. Promptly then closes to update.',
          _ => 'Promptly will close and open again by itself.',
        },
        null,
      ),
      UpdateFailed(:final message, :final release) => (
        Icons.error_outline,
        'The update did not work',
        message,
        release == null ? checkButton() : openPage(release),
      ),
    };

    return ListTile(
      key: const Key('about-update'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: t.muted),
      title: Text(title),
      subtitle: Text(subtitle, key: const Key('about-update-detail')),
      trailing: trailing,
    );
  }

  /// What pressing the install button does on this copy.
  static String get _installHint => switch (installKind) {
    InstallKind.windowsZip =>
      'Promptly installs itself for this user, with a Start menu entry, and opens the installed copy, which updates '
          'itself from then on. You can delete this unzipped folder afterwards. Open sessions are closed.',
    InstallKind.linuxDeb => 'Promptly asks for your password, installs it and opens again. Open sessions are closed.',
    InstallKind.linuxTarball => 'Promptly puts it in place of this folder and opens again. Open sessions are closed.',
    InstallKind.androidApk =>
      'Android asks you to confirm, then closes Promptly and installs it. Open sessions end; open Promptly again after.',
    _ => 'Promptly closes, installs it and opens again. Open sessions are closed.',
  };

  /// What to do with a new version where the app cannot install it itself.
  static String get _downloadHint {
    if (Platform.isWindows) return 'Get the installer from the release page. Once installed that way, later updates install from here.';
    if (Platform.isMacOS) return 'Get the new .dmg from the release page and drag Promptly to Applications again.';
    if (Platform.isLinux) return 'Get the new .deb or tarball from the release page.';
    if (Platform.isAndroid) return 'Get the new .apk from the release page and open it on this device.';
    return 'Get it from the release page.';
  }
}
