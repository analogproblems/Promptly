import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'src/rust/api/engine.dart' as rust;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The terminal font's licence, shown with every other one under About.
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['JetBrains Mono'], text);
  });
  // Loads the Rust engine (libpromptly_api) built by cargokit alongside the app.
  await RustLib.init();
  try {
    final dir = await getApplicationSupportDirectory();
    rust.setDataDir(path: dir.path);
  } catch (_) {
    // The engine falls back to a per-platform default.
  }
  runApp(const ProviderScope(child: PromptlyApp()));
}
