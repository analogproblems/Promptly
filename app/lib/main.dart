import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads the Rust engine (libpromptly_api) built by cargokit alongside the app.
  await RustLib.init();
  runApp(const ProviderScope(child: PromptlyApp()));
}
