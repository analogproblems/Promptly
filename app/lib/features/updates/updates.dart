import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../../core/version.dart';
import '../sessions/session_manager.dart';
import '../settings/settings_providers.dart';

/// Where new versions are published. `releases/latest` skips drafts and
/// pre-releases, so a tag that is still being tried never shows up here.
const latestReleaseApi = 'https://api.github.com/repos/analogproblems/Promptly/releases/latest';
const releasesPage = 'https://github.com/analogproblems/Promptly/releases/latest';

/// The release files each kind of install updates from. The Windows
/// installer's name is set in tools/windows-installer.iss, the Linux ones in
/// tools/package-linux.sh.
const windowsInstallerSuffix = '-windows-x64-setup.exe';
const linuxTarballSuffix = '-linux-x64.tar.gz';
const linuxDebSuffix = '_amd64.deb';

/// How this copy was installed, which decides how it can update itself.
enum InstallKind {
  /// Windows, from the setup program: runs the newer installer silently.
  windowsInstaller(windowsInstallerSuffix),

  /// Windows, unzipped by hand: runs the installer too, which installs
  /// Promptly for this user and opens that copy; it updates itself from then on.
  windowsZip(windowsInstallerSuffix),

  /// Linux, the .deb in /opt/promptly: installs the newer .deb, which asks
  /// for the password the way the system's own updates do.
  linuxDeb(linuxDebSuffix),

  /// Linux, the unpacked tarball, in a folder this user owns: puts the
  /// newer one in its place.
  linuxTarball(linuxTarballSuffix),

  /// Anything else (macOS, Android, a build from source) opens the release page.
  manual(null);

  const InstallKind(this.assetSuffix);

  /// The end of the release file's name this kind updates from.
  final String? assetSuffix;
}

/// One file attached to a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, required this.size, this.sha256});

  final String name;
  final String url;
  final int size;

  /// The checksum GitHub records for the upload, when it gives one.
  final String? sha256;
}

/// The newest published release, as much of it as the app needs.
class Release {
  const Release({required this.version, required this.pageUrl, this.assets = const []});

  final String version;
  final String pageUrl;
  final List<ReleaseAsset> assets;

  /// The file [kind] updates from, if the release has it.
  ReleaseAsset? assetFor(InstallKind kind) {
    final suffix = kind.assetSuffix;
    if (suffix == null) return null;
    for (final a in assets) {
      if (a.name.endsWith(suffix)) return a;
    }
    return null;
  }

  /// Read GitHub's answer for `releases/latest`. Null when it is not a
  /// release with a version tag (vX.Y.Z).
  static Release? fromGitHub(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String || parseVersion(tag) == null) return null;
    final page = json['html_url'];
    final assets = <ReleaseAsset>[];
    final list = json['assets'];
    if (list is List) {
      for (final a in list) {
        if (a is! Map) continue;
        final name = a['name'], url = a['browser_download_url'], size = a['size'];
        if (name is! String || url is! String || size is! int) continue;
        final digest = a['digest'];
        assets.add(
          ReleaseAsset(
            name: name,
            url: url,
            size: size,
            sha256: digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
          ),
        );
      }
    }
    return Release(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      pageUrl: page is String ? page : releasesPage,
      assets: assets,
    );
  }
}

/// X.Y.Z (with or without a leading v) as three numbers, or null.
List<int>? parseVersion(String v) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(v.trim());
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

/// Whether [candidate] is a later version than [current].
bool isNewer(String candidate, String current) {
  final a = parseVersion(candidate), b = parseVersion(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

/// iPhone and iPad builds come only from the App Store, which updates them.
bool get updateChecksSupported => !kIsWeb && !Platform.isIOS;

/// Set by tests to pretend the app was installed a certain way.
@visibleForTesting
InstallKind? installKindOverride;

/// How this copy was installed. Looked at once: it does not change while
/// the app runs.
InstallKind get installKind => installKindOverride ?? _installKind;

final InstallKind _installKind = _detectInstallKind();

InstallKind _detectInstallKind() {
  if (kIsWeb) return InstallKind.manual;
  final exe = File(Platform.resolvedExecutable);
  final dir = exe.parent.path;
  bool has(String name) => File('$dir${Platform.pathSeparator}$name').existsSync();
  if (Platform.isWindows) {
    // The installer leaves its uninstaller next to promptly.exe. The zip
    // carries the licence instead; a build from source has neither.
    if (has('unins000.exe')) return InstallKind.windowsInstaller;
    if (has('LICENSE.txt')) return InstallKind.windowsZip;
  } else if (Platform.isLinux) {
    // The .deb owns /opt/promptly, and dpkg keeps a list of its files.
    if (exe.path == '/opt/promptly/promptly' && File('/var/lib/dpkg/info/promptly.list').existsSync()) {
      return InstallKind.linuxDeb;
    }
    // The tarball's folder has its README and the licence beside the app.
    if (has('README.txt') && has('LICENSE')) return InstallKind.linuxTarball;
  }
  return InstallKind.manual;
}

/// Talks to GitHub. A provider, so tests can stand in for the network.
class UpdateService {
  const UpdateService();

  static const _timeout = Duration(seconds: 20);

  HttpClient _client() => HttpClient()
    ..connectionTimeout = _timeout
    ..userAgent = 'Promptly/$appVersion';

  Future<Release?> latest() async {
    final client = _client();
    try {
      final req = await client.getUrl(Uri.parse(latestReleaseApi)).timeout(_timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(_timeout);
      // No release published yet.
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) throw UpdateError('GitHub answered ${res.statusCode}. Try again later.');
      final body = await res.transform(utf8.decoder).join().timeout(_timeout);
      return Release.fromGitHub(jsonDecode(body));
    } on UpdateError {
      rethrow;
    } on TimeoutException {
      throw const UpdateError('GitHub did not answer in time. Check the connection and try again.');
    } on SocketException {
      throw const UpdateError('Could not reach GitHub. Check the connection and try again.');
    } on FormatException {
      throw const UpdateError('GitHub sent something unexpected. Try again later.');
    } finally {
      client.close(force: true);
    }
  }

  /// Fetch [asset] into a temporary folder, reporting progress from 0 to 1,
  /// and check it arrived whole.
  Future<File> download(ReleaseAsset asset, void Function(double) onProgress) async {
    final dir = await Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}promptly-update',
    ).create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
    final client = _client();
    try {
      final req = await client.getUrl(Uri.parse(asset.url)).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) throw UpdateError('The download failed (${res.statusCode}). Try again later.');
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.timeout(_timeout)) {
          sink.add(chunk);
          received += chunk.length;
          if (asset.size > 0) onProgress(received / asset.size);
        }
      } finally {
        await sink.close();
      }
      if (received != asset.size) throw const UpdateError('The download was cut short. Try again.');
      final want = asset.sha256;
      if (want != null && sha256.convert(await file.readAsBytes()).toString() != want) {
        throw const UpdateError('The download did not match the release. Try again.');
      }
      return file;
    } on UpdateError {
      await _remove(file);
      rethrow;
    } on TimeoutException {
      await _remove(file);
      throw const UpdateError('The download stalled. Check the connection and try again.');
    } on SocketException {
      await _remove(file);
      throw const UpdateError('The download failed. Check the connection and try again.');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _remove(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  /// Put the downloaded [file] in place of this copy, the way [kind] does
  /// it, and leave something running that opens the new version once this
  /// one has quit. The caller quits.
  Future<void> install(InstallKind kind, File file) async {
    switch (kind) {
      case InstallKind.windowsInstaller || InstallKind.windowsZip:
        // The installer shows its progress, closes anything still holding
        // the files, and opens Promptly again when it is done (the [Run]
        // entry in the .iss). From the zip, that is a new installed copy.
        await Process.start(
          file.path,
          ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/FORCECLOSEAPPLICATIONS'],
          mode: ProcessStartMode.detached,
        );
      case InstallKind.linuxDeb:
        await _installDeb(file);
        await _openWhenClosed('/opt/promptly/promptly');
      case InstallKind.linuxTarball:
        await _replaceFolder(file);
      case InstallKind.manual:
        throw const UpdateError('This copy cannot update itself. Download the new version from the release page.');
    }
  }

  /// Install the .deb as root. pkexec asks for the password in the
  /// desktop's own dialog, as the system's updates do. apt-get rather than
  /// dpkg, so a dependency a newer version adds comes along too.
  Future<void> _installDeb(File deb) async {
    final ProcessResult r;
    try {
      r = await Process.run('pkexec', ['apt-get', 'install', '-y', deb.absolute.path]);
    } on ProcessException {
      throw const UpdateError('This system has no way to ask for the password (pkexec). Install the .deb from the release page instead.');
    }
    switch (r.exitCode) {
      case 0:
        return;
      // The password dialog was dismissed.
      case 126:
        throw const UpdateCancelled();
      // No password dialog to show, or not allowed to install.
      case 127:
        throw const UpdateError('The system did not let Promptly install it. Install the .deb from the release page instead.');
      default:
        throw const UpdateError('The package manager could not install it. Try again, or install the .deb from the release page.');
    }
  }

  /// Unpack the new tarball beside this copy's folder, swap the two, and
  /// open the new one once this has quit. The folder keeps its name, so
  /// launchers that point into it still work.
  Future<void> _replaceFolder(File tarball) async {
    final dir = File(Platform.resolvedExecutable).parent;
    final old = await swapFolder(tarball, dir);
    // This copy runs from the old folder until it quits; Linux is fine with
    // that, and the folder goes once it has.
    await _openWhenClosed('${dir.path}/promptly', remove: old.path);
  }

  /// Unpack [tarball] beside [dir] and swap it in. Returns where the old
  /// folder went.
  @visibleForTesting
  Future<Directory> swapFolder(File tarball, Directory dir) async {
    final staging = Directory('${dir.path}.update');
    final old = Directory('${dir.path}.old');
    try {
      for (final d in [staging, old]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
      await staging.create();
    } on FileSystemException {
      throw UpdateError('Promptly cannot write beside its folder (${dir.parent.path}). Download the new tarball from the release page instead.');
    }
    try {
      final r = await Process.run('tar', ['-xzf', tarball.path, '-C', staging.path]);
      // The tarball holds one folder, promptly-X.Y.Z-linux-x64.
      final unpacked = r.exitCode == 0 ? staging.listSync().whereType<Directory>().toList() : const <Directory>[];
      if (unpacked.length != 1 || !File('${unpacked.single.path}/promptly').existsSync()) {
        throw const UpdateError('The download could not be unpacked. Try again.');
      }
      await dir.rename(old.path);
      try {
        await unpacked.single.rename(dir.path);
      } catch (_) {
        await old.rename(dir.path);
        rethrow;
      }
    } on FileSystemException {
      throw const UpdateError('Promptly could not swap in the new version. Nothing changed. Download it from the release page instead.');
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
    return old;
  }

  /// Wait in the background for this process to end, then (after removing
  /// [remove], if given) open [app].
  Future<void> _openWhenClosed(String app, {String? remove}) async {
    await Process.start(
      '/bin/sh',
      [
        '-c',
        r'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; [ -n "$2" ] && rm -rf "$2"; exec "$0"',
        app,
        '$pid',
        remove ?? '',
      ],
      mode: ProcessStartMode.detached,
    );
  }
}

final updateServiceProvider = Provider<UpdateService>((_) => const UpdateService());

class UpdateError implements Exception {
  const UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The person said no (dismissed the password dialog): back to the offer.
class UpdateCancelled extends UpdateError {
  const UpdateCancelled() : super('The update was cancelled.');
}

/// Where the update check stands, for the About page and the reminder.
sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate();
}

class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.release);
  final Release release;

  /// This copy can update itself, and the release has the file it needs.
  bool get canInstallInApp => release.assetFor(installKind) != null;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.release, this.progress);
  final Release release;
  final double progress;
}

/// The installer is running and the app is about to close.
class UpdateInstalling extends UpdateState {
  const UpdateInstalling(this.release);
  final Release release;
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.message, {this.release});
  final String message;

  /// Set when the check worked and the download or install did not.
  final Release? release;
}

class UpdateNotifier extends Notifier<UpdateState> {
  @override
  UpdateState build() => const UpdateIdle();

  /// Ask GitHub for the newest release. Returns it when it is newer than
  /// this copy.
  Future<Release?> check() async {
    if (state is UpdateChecking || state is UpdateDownloading || state is UpdateInstalling) return null;
    state = const UpdateChecking();
    try {
      final release = await ref.read(updateServiceProvider).latest();
      if (release != null && isNewer(release.version, appVersion)) {
        state = UpdateAvailable(release);
        return release;
      }
      state = const UpdateUpToDate();
    } on UpdateError catch (e) {
      state = UpdateFailed(e.message);
    } catch (_) {
      state = const UpdateFailed('The check failed. Try again later.');
    }
    return null;
  }

  /// Fetch the file this kind of install updates from, put it in place and
  /// quit. What [UpdateService.install] leaves running opens the new version.
  Future<void> installAndRestart(Release release) async {
    final kind = installKind;
    final asset = release.assetFor(kind);
    if (asset == null || state is UpdateDownloading || state is UpdateInstalling) return;
    final service = ref.read(updateServiceProvider);
    state = UpdateDownloading(release, 0);
    try {
      final file = await service.download(asset, (p) {
        if (state is UpdateDownloading) state = UpdateDownloading(release, p.clamp(0, 1).toDouble());
      });
      state = UpdateInstalling(release);
      await service.install(kind, file);
    } on UpdateCancelled {
      state = UpdateAvailable(release);
      return;
    } on UpdateError catch (e) {
      state = UpdateFailed(e.message, release: release);
      return;
    } catch (_) {
      state = UpdateFailed('The update could not be installed. Download it from the release page instead.', release: release);
      return;
    }
    // Close the sessions the way Quit does, so the installer finds the files free.
    for (final e in ref.read(sessionManagerProvider)) {
      ref.read(sessionManagerProvider.notifier).close(e.id);
    }
    exit(0);
  }
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(UpdateNotifier.new);

/// Whether Promptly looks for a new version by itself. Off until someone
/// turns it on: nothing leaves the device unless you set that up.
class UpdateCheckNotifier extends Notifier<bool> {
  @override
  bool build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(SettingKeys.updateCheck);
      return raw != null && jsonDecode(raw) == true;
    } catch (_) {
      return false;
    }
  }

  /// Whether anyone has said yes or no yet. Until then the app offers once
  /// to turn it on (UpdateReminder), and that offer writes the answer.
  bool get chosen {
    try {
      return ref.read(engineProvider).settingGet(SettingKeys.updateCheck) != null;
    } catch (_) {
      return true;
    }
  }

  void set(bool on) {
    state = on;
    try {
      ref.read(engineProvider).settingSet(SettingKeys.updateCheck, jsonEncode(on));
    } catch (_) {}
  }
}

final updateCheckProvider = NotifierProvider<UpdateCheckNotifier, bool>(UpdateCheckNotifier.new);
