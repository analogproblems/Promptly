import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/file_picker.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import '../terminal/font_files.dart';
import '../terminal/terminal_fonts.dart';
import 'settings_providers.dart';

/// Which font the terminal uses: the built-in one, a font file the person
/// added, or a monospaced font installed on the device. Open sessions
/// change as you tap.
class FontsScreen extends ConsumerWidget {
  const FontsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final chosen = ref.watch(fontFamilyProvider);
    final added = ref.watch(addedFontsProvider).value ?? const <FontFamilyFiles>[];
    final installed = ref.watch(installedFontsProvider);
    final setting = ref.read(fontFamilyProvider.notifier);

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(left: 4, top: 24, bottom: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Terminal font',
          leading: IconButton(
            tooltip: 'Back to settings',
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.arrow_back),
          ),
          trailing: OutlinedButton.icon(
            key: const Key('font-add'),
            onPressed: () => addFontFile(context, ref),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a font file'),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              const FontPreview(),
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 12),
                child: Text(
                  'Open sessions change as you tap. A font file you add is copied into Promptly\'s data folder, '
                  'so the original can be moved or deleted.',
                  style: TextStyle(color: t.muted, fontSize: 13),
                ),
              ),
              heading('BUILT IN'),
              Card(
                child: _FontTile(
                  family: PromptlyTokens.monoFamily,
                  subtitle: 'The usual font',
                  selected: chosen.isEmpty,
                  onTap: () => setting.set(''),
                ),
              ),
              if (added.isNotEmpty) ...[
                heading('YOUR FONTS'),
                Card(
                  child: Column(
                    children: [
                      for (final f in added)
                        _FontTile(
                          family: f.family,
                          subtitle: f.monospaced ? null : 'Not monospaced, so columns may not line up',
                          selected: chosen == f.family,
                          onTap: () => setting.set(f.family),
                          onRemove: () => _removeFont(context, ref, f),
                        ),
                    ],
                  ),
                ),
              ],
              heading('ON THIS DEVICE'),
              ...installed.when(
                loading: () => [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('Looking for fonts…', style: TextStyle(color: t.muted, fontSize: 13)),
                  ),
                ],
                error: (_, _) => [_none(t)],
                data: (fonts) => fonts.isEmpty
                    ? [_none(t)]
                    : [
                        Card(
                          child: Column(
                            children: [
                              for (final f in fonts)
                                _FontTile(
                                  family: f.family,
                                  selected: chosen == f.family,
                                  onTap: () => setting.set(f.family),
                                ),
                            ],
                          ),
                        ),
                      ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _none(PromptlyTokens t) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      'No other monospaced fonts found here. Add a font file instead.',
      style: TextStyle(color: t.muted, fontSize: 13),
    ),
  );
}

/// A line of shell in the terminal's font as it stands, with arrows and
/// comparisons that become ligatures where turned on, and a Nerd Font
/// branch symbol.
class FontPreview extends ConsumerWidget {
  const FontPreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final font = ref.watch(terminalFontProvider);
    final features = font.ligatures
        ? const [FontFeature.enable('liga'), FontFeature.enable('calt')]
        : const [FontFeature.disable('liga'), FontFeature.disable('calt')];
    return Container(
      key: const Key('font-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.background,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
      ),
      child: Text(
        '~/src  main \$ make && ./run -> 0 != 1\n'
        'if (a <= b || c >= d) => {} // 0O 1lI',
        style: TextStyle(
          fontFamily: font.family,
          fontFamilyFallback: font.fallback,
          fontFeatures: features,
          fontSize: 14,
          height: 1.4,
          color: t.text,
        ),
      ),
    );
  }
}

class _FontTile extends StatelessWidget {
  const _FontTile({required this.family, required this.selected, required this.onTap, this.subtitle, this.onRemove});

  final String family;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      key: Key('font-$family'),
      selected: selected,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? t.accent : t.muted,
      ),
      title: Text(family),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: onRemove == null
          ? null
          : IconButton(
              key: Key('font-remove-$family'),
              tooltip: 'Remove $family',
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline),
            ),
      onTap: onTap,
    );
  }
}

/// Pick a font file, keep a copy of it, and use it.
Future<void> addFontFile(BuildContext context, WidgetRef ref) async {
  final picked = await ref.read(binaryFilePickerProvider)(
    label: 'Font files',
    extensions: const ['ttf', 'otf', 'ttc'],
  );
  if (picked == null || !context.mounted) return;
  try {
    final family = await ref.read(fontLibraryProvider).add(picked.name, picked.bytes);
    ref.invalidate(addedFontsProvider);
    ref.read(fontFamilyProvider.notifier).set(family);
    if (context.mounted) notYet(context, 'Added $family. The terminal uses it now.');
  } on FormatException {
    if (context.mounted) {
      notYet(context, '${picked.name} isn\'t a font Promptly can read. Choose a .ttf or .otf file.');
    }
  } catch (e) {
    if (context.mounted) notYet(context, 'Could not add ${picked.name}: $e');
  }
}

Future<void> _removeFont(BuildContext context, WidgetRef ref, FontFamilyFiles font) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove ${font.family}?'),
      content: const Text('Promptly deletes its copy of the font. Sessions using it switch to the built-in font.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('font-remove-ok'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(fontLibraryProvider).remove(font);
  } catch (e) {
    if (context.mounted) notYet(context, 'Could not remove ${font.family}: $e');
    return;
  }
  if (ref.read(fontFamilyProvider) == font.family) ref.read(fontFamilyProvider.notifier).set('');
  ref.invalidate(addedFontsProvider);
}
