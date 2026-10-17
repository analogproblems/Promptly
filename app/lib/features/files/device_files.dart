import 'dart:io' as io;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// A file on this device the person picked to upload.
typedef PickedFile = ({String path, String name});

/// Moving files between the server and the rest of this device when there
/// is no second pane to drag to, as on a phone: pick files to upload,
/// choose where a download goes, and hand a file to another app. Tests swap
/// in a fake.
abstract class DeviceFiles {
  /// Whether downloads are saved through a dialog that names a place
  /// (computers). Phones have none; a download goes to the share sheet,
  /// where the person saves it to Files or sends it on.
  bool get savesWithDialog;

  /// Files to upload, chosen in the system picker; empty if cancelled.
  Future<List<PickedFile>> pick();

  /// Where to save a download of `name`, from the save dialog; null if
  /// cancelled. Only where [savesWithDialog].
  Future<String?> saveLocation(String name);

  /// A fresh path in the app's cache folder for a download of `name`,
  /// to save or open from.
  Future<String> scratchPath(String name);

  /// Offer a downloaded file to save or send: the share sheet.
  Future<void> share(String path, {Rect? origin});

  /// Open a downloaded file in whichever app handles it.
  Future<void> open(String path, {Rect? origin});
}

/// Phones: the share sheet stands in for both a save dialog and "Open with".
bool get _phone => !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);

class PlatformDeviceFiles extends DeviceFiles {
  @override
  bool get savesWithDialog => !_phone;

  @override
  Future<List<PickedFile>> pick() async {
    final files = await openFiles();
    return [for (final f in files) (path: f.path, name: f.name)];
  }

  @override
  Future<String?> saveLocation(String name) async => (await getSaveLocation(suggestedName: name))?.path;

  /// Downloads kept for saving or opening sit here for a day, long enough
  /// for the app they went to to read them, then go on the next download.
  static const _keep = Duration(days: 1);

  @override
  Future<String> scratchPath(String name) async {
    final base = io.Directory('${(await getTemporaryDirectory()).path}/promptly-files');
    try {
      if (await base.exists()) {
        final now = DateTime.now();
        await for (final old in base.list()) {
          if (now.difference((await old.stat()).modified) > _keep) await old.delete(recursive: true);
        }
      }
    } catch (_) {
      // Tidying is best effort; the cache is the system's to clear too.
    }
    final dir = io.Directory('${base.path}/${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    return '${dir.path}/$name';
  }

  @override
  Future<void> share(String path, {Rect? origin}) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], sharePositionOrigin: origin));
  }

  @override
  Future<void> open(String path, {Rect? origin}) async {
    if (_phone) return share(path, origin: origin);
    if (!await launchUrl(Uri.file(path))) throw 'No app on this device opens that kind of file.';
  }
}

final deviceFilesProvider = Provider<DeviceFiles>((_) => PlatformDeviceFiles());
