import 'dart:async';

import 'package:flutter/services.dart';

/// How long a copied secret stays on the clipboard.
const secretClipboardTime = Duration(minutes: 1);

/// Copy a secret (a private key, a recovery code, a join code) and take it
/// off the clipboard again after [secretClipboardTime], unless something
/// else was copied over it meanwhile. Clipboard managers may keep their
/// own copy; this is about the next paste.
Future<void> copySecret(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  Timer(secretClipboardTime, () async {
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {
      // The clipboard could not be read; it is left as it is.
    }
  });
}
