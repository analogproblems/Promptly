import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme/theme.dart';
import 'features/settings/settings_providers.dart';

/// The root widget. Themes come from the design tokens; navigation from the
/// router. Everything else is a feature under `features/`.
class PromptlyApp extends ConsumerWidget {
  const PromptlyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Promptly',
      debugShowCheckedModeBanner: false,
      theme: buildPromptlyTheme(Brightness.light),
      darkTheme: buildPromptlyTheme(Brightness.dark),
      themeMode: themeMode,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
