import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme/theme.dart';
import 'features/sessions/session_manager.dart';
import 'features/settings/settings_providers.dart';
import 'features/sync/sync_providers.dart';

/// The root widget. Themes come from the design tokens; navigation from the
/// router. Everything else is a feature under `features/`.
class PromptlyApp extends ConsumerStatefulWidget {
  const PromptlyApp({super.key});

  @override
  ConsumerState<PromptlyApp> createState() => _PromptlyAppState();
}

class _PromptlyAppState extends ConsumerState<PromptlyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The system's reduced-motion setting decides the page transitions.
  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final reducedMotion = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    return MaterialApp.router(
      title: 'Promptly',
      debugShowCheckedModeBanner: false,
      theme: buildPromptlyTheme(Brightness.light, reducedMotion: reducedMotion),
      darkTheme: buildPromptlyTheme(Brightness.dark, reducedMotion: reducedMotion),
      themeMode: themeMode,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => TerminalThemeSync(child: SyncRefresh(child: child ?? const SizedBox.shrink())),
    );
  }
}

/// Keeps every open session on the chosen terminal theme. Sits under the
/// MaterialApp so it sees the app's effective brightness, which decides the
/// theme when the setting is "match the app".
class TerminalThemeSync extends ConsumerStatefulWidget {
  const TerminalThemeSync({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TerminalThemeSync> createState() => _TerminalThemeSyncState();
}

class _TerminalThemeSyncState extends ConsumerState<TerminalThemeSync> {
  String? _applied;

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(terminalThemeProvider);
    final resolved = resolveTerminalTheme(setting, Theme.of(context).brightness);
    if (resolved != _applied) {
      _applied = resolved;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(sessionManagerProvider.notifier).applyTheme(resolved);
      });
    }
    return widget.child;
  }
}
