import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// Set by tests to pretend to be a phone, or a desktop.
@visibleForTesting
bool? touchPlatformOverride;

/// Phones and tablets: a soft keyboard and touch, with no Ctrl, Alt or
/// Escape of their own.
bool get isTouchPlatform => touchPlatformOverride ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));
