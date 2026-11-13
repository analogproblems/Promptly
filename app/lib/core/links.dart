import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

/// Where the project lives, for the help and about screens.
abstract final class AppLinks {
  static const website = 'https://jasondwhyte.github.io/Promptly/';
  static const guide = 'https://jasondwhyte.github.io/Promptly/guide/';
  static const source = 'https://github.com/jasondwhyte/Promptly';
  static const issues = 'https://github.com/jasondwhyte/Promptly/issues';
  static const privacy = 'https://jasondwhyte.github.io/Promptly/privacy/';
}

/// Open a link in the system browser (or mail client, and so on). Linux
/// goes through xdg-open first, which reports back where the GTK route
/// sometimes does not; everything else uses the platform opener.
Future<bool> openExternalLink(String uri) async {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.scheme.isEmpty) return false;
  if (!kIsWeb && Platform.isLinux) {
    try {
      final result = await Process.run('xdg-open', [uri]).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) return true;
    } catch (_) {
      // No xdg-open: fall through to the platform opener.
    }
  }
  try {
    return await launchUrl(parsed, mode: LaunchMode.externalApplication).timeout(const Duration(seconds: 5));
  } catch (_) {
    return false;
  }
}
