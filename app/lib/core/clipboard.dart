import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// How long a copied secret stays on the clipboard.
const secretClipboardTime = Duration(minutes: 1);

/// The secret waiting to be taken off the clipboard, if any.
String? _pending;
Timer? _timer;
AppLifecycleListener? _lifecycle;

/// Copy a secret (a private key, a recovery code, a join code) and take it
/// off the clipboard again after [secretClipboardTime], unless something
/// else was copied over it meanwhile.
///
/// Some systems (Android 10 and later) don't let an app in the background
/// read the clipboard, so when the minute is up while Promptly is away, the
/// secret is taken off when Promptly comes back instead. Clipboard managers
/// may keep their own copy, and a Promptly that is closed can't tidy up;
/// this is about the next paste.
Future<void> copySecret(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  _pending = text;
  _timer?.cancel();
  _timer = Timer(secretClipboardTime, () {
    _timer = null;
    _tidy();
  });
  _lifecycle ??= AppLifecycleListener(onResume: () {
    if (_timer == null) _tidy();
  });
}

/// Clear the clipboard if it still holds the secret. When it can't be read,
/// the secret stays pending for the next time Promptly comes back.
Future<void> _tidy() async {
  final secret = _pending;
  if (secret == null) return;
  final ClipboardData? now;
  try {
    now = await Clipboard.getData(Clipboard.kTextPlain);
  } catch (_) {
    return;
  }
  if (now == null || _pending != secret) return;
  if (now.text == secret) await Clipboard.setData(const ClipboardData(text: ''));
  _pending = null;
  _lifecycle?.dispose();
  _lifecycle = null;
}
