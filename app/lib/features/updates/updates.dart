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

/// The Windows installer's name ends with this; see tools/windows-installer.iss.
const windowsInstallerSuffix = '-windows-x64-setup.exe';

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
  const Release({required this.version, required this.pageUrl, this.windowsInstaller});

  final String version;
  final String pageUrl;
  final ReleaseAsset? windowsInstaller;

  /// Read GitHub's answer for `releases/latest`. Null when it is not a
  /// release with a version tag (vX.Y.Z).
  static Release? fromGitHub(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String || parseVersion(tag) == null) return null;
    final page = json['html_url'];
    ReleaseAsset? installer;
    final assets = json['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = a['name'], url = a['browser_download_url'], size = a['size'];
        if (name is String && url is String && size is int && name.endsWith(windowsInstallerSuffix)) {
          final digest = a['digest'];
          installer = ReleaseAsset(
            name: name,
            url: url,
            size: size,
            sha256: digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
          );
        }
      }
    }
    return Release(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      pageUrl: page is String ? page : releasesPage,
      windowsInstaller: installer,
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

/// Set by tests to pretend the app was installed by the Windows installer.
@visibleForTesting
bool? installedByInstallerOverride;

/// The Windows installer leaves its uninstaller next to promptly.exe. A
/// copy unpacked from the zip has none, and is updated by hand.
bool get installedByInstaller {
  final o = installedByInstallerOverride;
  if (o != null) return o;
  if (kIsWeb || !Platform.isWindows) return false;
  final dir = File(Platform.resolvedExecutable).parent.path;
  return File('$dir${Platform.pathSeparator}unins000.exe').existsSync();
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

  /// Start the installer on its own and leave it to replace this copy. It
  /// shows its progress, closes anything still holding the files, and opens
  /// Promptly again when it is done (the [Run] entry in the .iss).
  Future<void> runInstaller(File installer) async {
    await Process.start(
      installer.path,
      ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/FORCECLOSEAPPLICATIONS'],
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

  /// This copy can update itself: a Windows install with an installer to fetch.
  bool get canInstallInApp => installedByInstaller && release.windowsInstaller != null;
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

  /// Fetch the Windows installer, start it and quit. The installer opens
  /// the new version once it has replaced this one.
  Future<void> installAndRestart(Release release) async {
    final asset = release.windowsInstaller;
    if (asset == null || state is UpdateDownloading || state is UpdateInstalling) return;
    final service = ref.read(updateServiceProvider);
    state = UpdateDownloading(release, 0);
    try {
      final file = await service.download(asset, (p) {
        if (state is UpdateDownloading) state = UpdateDownloading(release, p.clamp(0, 1).toDouble());
      });
      state = UpdateInstalling(release);
      await service.runInstaller(file);
    } on UpdateError catch (e) {
      state = UpdateFailed(e.message, release: release);
      return;
    } catch (_) {
      state = UpdateFailed('The installer could not be started. Download it from the release page instead.', release: release);
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

  void set(bool on) {
    state = on;
    try {
      ref.read(engineProvider).settingSet(SettingKeys.updateCheck, jsonEncode(on));
    } catch (_) {}
  }
}

final updateCheckProvider = NotifierProvider<UpdateCheckNotifier, bool>(UpdateCheckNotifier.new);
