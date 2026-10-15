import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/file_picker.dart';
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
          trailing: OutlinedButton.icon(
            key: const Key('theme-import'),
            onPressed: () => importTheme(context, ref),
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: const Text('Import'),
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
                  subtitle: const Text('Promptly Dark with the dark look, Promptly Light with the light one.'),
                  value: auto,
                  onChanged: (on) => notifier.set(on ? TerminalThemeNotifier.auto : resolved),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  auto ? 'Or pick one to keep. Open sessions change as you tap.' : 'Open sessions change as you tap.',
                  style: TextStyle(color: t.muted, fontSize: 13),
                ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final theme in themes.where((th) => th.builtin))
                    ThemeCard(
                      key: Key('theme-${theme.id}'),
                      theme: theme,
                      selected: theme.id == resolved,
                      onTap: () => notifier.set(theme.id),
                    ),
                ],
              ),
              if (themes.any((th) => !th.builtin)) ...[
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 24, bottom: 8),
                  child: Text(
                    'YOUR THEMES',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: t.muted),
                  ),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final theme in themes.where((th) => !th.builtin))
                      ThemeCard(
                        key: Key('theme-${theme.id}'),
                        theme: theme,
                        selected: theme.id == resolved,
                        onTap: () => notifier.set(theme.id),
                        onDelete: () => _deleteTheme(context, ref, theme),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Pick a theme file, show what is in it, and save the schemes wanted.
Future<void> importTheme(BuildContext context, WidgetRef ref) async {
  final picked = await ref.read(filePickerProvider)(
    label: 'Theme files',
    extensions: const ['itermcolors', 'json', 'toml', 'yml', 'yaml'],
  );
  if (picked == null || !context.mounted) return;
  final List<ThemeInfo> found;
  try {
    found = ref.read(engineProvider).themeImportPreview(picked.text, picked.name);
  } catch (e) {
    notYet(context, 'Could not read ${picked.name}: $e');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => _ImportThemesDialog(filename: picked.name, themes: found),
  );
}

Future<void> _deleteTheme(BuildContext context, WidgetRef ref, ThemeInfo theme) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove ${theme.name}?'),
      content: const Text('Sessions using it switch to Promptly\'s own theme.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('theme-delete-ok'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    ref.read(engineProvider).themeDelete(theme.id);
    if (ref.read(terminalThemeProvider) == theme.id) {
      ref.read(terminalThemeProvider.notifier).set(TerminalThemeNotifier.auto);
    }
    ref.invalidate(themesProvider);
  } catch (e) {
    notYet(context, 'Could not remove the theme: $e');
  }
}

class _ImportThemesDialog extends ConsumerStatefulWidget {
  const _ImportThemesDialog({required this.filename, required this.themes});

  final String filename;
  final List<ThemeInfo> themes;

  @override
  ConsumerState<_ImportThemesDialog> createState() => _ImportThemesDialogState();
}

class _ImportThemesDialogState extends ConsumerState<_ImportThemesDialog> {
  final Set<int> _saved = {};
  String? _error;

  void _save(int i) {
    try {
      final saved = ref.read(engineProvider).themeSave(widget.themes[i]);
      ref.invalidate(themesProvider);
      setState(() {
        _saved.add(i);
        _error = null;
      });
      if (widget.themes.length == 1) {
        ref.read(terminalThemeProvider.notifier).set(saved.id);
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final one = widget.themes.length == 1;
    return AlertDialog(
      title: Text(one ? 'Import ${widget.themes.first.name}?' : '${widget.themes.length} themes in ${widget.filename}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = 0; i < widget.themes.length; i++)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ThemeCard(theme: widget.themes[i], selected: _saved.contains(i), onTap: () {}),
                    if (!one)
                      TextButton(
                        key: Key('theme-import-save-$i'),
                        onPressed: _saved.contains(i) ? null : () => _save(i),
                        child: Text(_saved.contains(i) ? 'Saved' : 'Save'),
                      ),
                  ],
                ),
              if (_error != null) Text(_error!, style: TextStyle(color: t.danger, fontSize: 13)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(one ? 'Cancel' : 'Done')),
        if (one)
          FilledButton(
            key: const Key('theme-import-save-0'),
            onPressed: () => _save(0),
            child: const Text('Import and use'),
          ),
      ],
    );
  }
}

/// One theme: a small sample screen in its colours, its swatches and name.
class ThemeCard extends StatelessWidget {
  const ThemeCard({super.key, required this.theme, required this.selected, required this.onTap, this.onDelete});

  final ThemeInfo theme;
  final bool selected;
  final VoidCallback onTap;

  /// Shown as a small remove button on imported themes.
  final VoidCallback? onDelete;

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
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
          width: 236,
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
            border: Border.all(color: selected ? t.accent : t.border, width: selected ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(PromptlyTokens.panelRadius - 1)),
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
                      Text(theme.dark ? 'dark' : 'light', style: TextStyle(fontSize: 11, color: t.muted)),
                    if (onDelete != null)
                      IconButton(
                        key: Key('theme-delete-${theme.id}'),
                        tooltip: 'Remove theme',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        onPressed: onDelete,
                        icon: Icon(Icons.delete_outline, color: t.muted),
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
                  decoration: BoxDecoration(color: _c(a[i]), borderRadius: BorderRadius.circular(2)),
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
                decoration: BoxDecoration(color: _c(theme.ansi[i]), borderRadius: BorderRadius.circular(2)),
              ),
            ),
        ],
      ),
    );
  }
}
