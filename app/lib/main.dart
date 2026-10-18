import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/device_key.dart';
import 'core/licences.dart';
import 'src/rust/api/engine.dart' as rust;
import 'src/rust/api/store.dart' as rust_store;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The terminal font's and the engine's libraries' licences, shown with
  // every other one under About.
  registerLicences();
  // Loads the Rust engine (libpromptly_api) built by cargokit alongside the app.
  await RustLib.init();
  try {
    final dir = await getApplicationSupportDirectory();
    rust.setDataDir(path: dir.path);
  } catch (_) {
    // The engine falls back to a per-platform default.
  }
  // Before anything touches the local database or saved secrets: the
  // engine will not open the database until it has heard one of these.
  try {
    switch (await loadDeviceKey()) {
      case DeviceKeyReady(:final bytes):
        rust_store.setDeviceKey(key: bytes);
      case DeviceKeyRefused():
        rust_store.setDeviceKeyUnavailable();
      case DeviceKeyNoStorage():
        // Secrets and the database stay unencrypted, and Settings says so.
        rust_store.setNoDeviceKey();
    }
  } catch (_) {
    // The engine opened its stores already; nothing to change.
  }
  runApp(const ProviderScope(child: PromptlyApp()));
}
