import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import 'settings_providers.dart';

Color _c(int rgb) => Color(0xFF000000 | rgb);

/// The theme gallery. Tapping a card applies the theme to every open session
/// straight away, so picking is the preview.
class ThemesScreen extends ConsumerWidget {
  const ThemesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final themes = ref.watch(themesProvider);
    final setting = ref.watch(terminalThemeProvider);
    final auto = setting == TerminalThemeNotifier.auto;
    final resolved = resolveTerminalTheme(setting, Theme.of(context).brightness);
    final notifier = ref.read(terminalThemeProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Terminal theme',
          leading: IconButton(
            tooltip: 'Back to settings',
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Card(
                child: SwitchListTile(
                  key: const Key('theme-auto'),
                  title: const Text('Match the app'),
                  subtitle: const Text(
                    'Promptly Dark with the dark look, Promptly Light with the light one.',
                  ),
                  value: auto,
                  onChanged: (on) => notifier.set(on ? TerminalThemeNotifier.auto : resolved),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  auto
                      ? 'Or pick one to keep. Open sessions change as you tap.'
                      : 'Open sessions change as you tap.',
                  style: TextStyle(color: t.muted, fontSize: 13),
                ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final theme in themes)
                    ThemeCard(
                      key: Key('theme-${theme.id}'),
                      theme: theme,
                      selected: theme.id == resolved,
                      onTap: () => notifier.set(theme.id),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One theme: a small sample screen in its colours, its swatches and name.
class ThemeCard extends StatelessWidget {
  const ThemeCard({super.key, required this.theme, required this.selected, required this.onTap});

  final ThemeInfo theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      selected: selected,
      label: theme.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 236,
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
            border: Border.all(
              color: selected ? t.accent : t.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(PromptlyTokens.panelRadius - 1),
                ),
                child: ThemeSample(theme: theme),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        theme.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check_circle, size: 18, color: t.accent)
                    else
                      Text(
                        theme.dark ? 'dark' : 'light',
                        style: TextStyle(fontSize: 11, color: t.muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A few lines of pretend terminal output in the theme's colours.
class ThemeSample extends StatelessWidget {
  const ThemeSample({super.key, required this.theme});

  final ThemeInfo theme;

  @override
  Widget build(BuildContext context) {
    final fg = _c(theme.foreground);
    final a = theme.ansi;
    TextSpan s(String text, [int? rgb, FontWeight? w]) => TextSpan(
          text: text,
          style: TextStyle(color: rgb == null ? fg : _c(rgb), fontWeight: w),
        );
    return Container(
      color: _c(theme.background),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: monoStyle(context, size: 10.5, color: fg).copyWith(height: 1.45),
              children: [
                s('deploy', a[2], FontWeight.w600),
                s('@'),
                s('web-1', a[4], FontWeight.w600),
                s(':'),
                s('~', a[5]),
                s('\$ git status\n'),
                s('On branch '),
                s('main\n', a[3]),
                s('modified:   ', a[1]),
                s('src/app.dart\n'),
                s('✓ 42 passed', a[2]),
                s(' '),
                s('✗ 0 failed', a[1]),
                s(' '),
                s('warn', a[3]),
                s(' '),
                s('info\n', a[6]),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < 8; i++)
                Container(
                  width: 14,
                  height: 10,
                  margin: const EdgeInsets.only(right: 3),
                  decoration: BoxDecoration(
                    color: _c(a[i]),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              const Spacer(),
              Container(width: 7, height: 12, color: _c(theme.cursor)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The four-swatch strip used on the settings row.
class ThemeSwatches extends StatelessWidget {
  const ThemeSwatches({super.key, required this.theme});

  final ThemeInfo theme;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: 44,
      height: 28,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _c(theme.background),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: [
          for (final i in const [1, 2, 4, 5])
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: _c(theme.ansi[i]),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
