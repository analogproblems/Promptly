import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// Set by tests to pretend to be a phone, or a desktop.
@visibleForTesting
bool? touchPlatformOverride;

/// Phones and tablets: a soft keyboard and touch, with no Ctrl, Alt or
/// Escape of their own. `PROMPTLY_TOUCH=1` in the environment makes a
/// desktop build behave like one, for trying the phone layout and taking
/// its screenshots.
bool get isTouchPlatform =>
    touchPlatformOverride ??
    (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.environment['PROMPTLY_TOUCH'] == '1'));

/// Set by tests to pretend to be Android, or not.
@visibleForTesting
bool? androidOverride;

/// Android, where open sessions need a foreground service to keep running
/// while the app is in the background.
bool get isAndroid => androidOverride ?? (!kIsWeb && Platform.isAndroid);
