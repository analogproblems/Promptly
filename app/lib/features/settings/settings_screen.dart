import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/platform.dart';
import '../../core/theme/tokens.dart';
import '../../core/version.dart';
import '../shell/empty_state.dart';
import 'settings_providers.dart';
import '../hosts/csv_import.dart';
import '../hosts/ssh_config_import.dart';
import '../lock/lock_settings.dart';
import '../sessions/session_manager.dart' show sessionManagerProvider;
import '../sessions/sessions_screen.dart' show supportsLocalShell;
import '../sync/sync_providers.dart';
import '../updates/updates.dart';
import 'themes_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final engine = ref.watch(engineProvider);
    final themeMode = ref.watch(themeModeProvider);
    final terminalSetting = ref.watch(terminalThemeProvider);
    final terminalId = resolveTerminalTheme(terminalSetting, Theme.of(context).brightness);
    final themes = ref.watch(themesProvider);
    final sync = ref.watch(syncStatusProvider).value;
    final terminalTheme = themes.cast<ThemeInfo?>().firstWhere(
      (th) => th!.id == terminalId,
      orElse: () => themes.isEmpty ? null : themes.first,
    );
    final secrets = engine.secretsState();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Settings'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              _Section(
                title: 'Appearance',
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      // Full width, so the buttons sit at the far side on one
                      // line and drop below the label with large text.
                      child: SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          runSpacing: 8,
                          children: [
                            Text('App look', style: TextStyle(color: t.text)),
                            SegmentedButton<ThemeMode>(
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                              ],
                              selected: {themeMode},
                              onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Divider(height: 1, color: t.border),
                    ListTile(
                      key: const Key('terminal-theme'),
                      leading: terminalTheme == null ? null : ThemeSwatches(theme: terminalTheme),
                      title: const Text('Terminal theme'),
                      subtitle: Text(
                        terminalSetting == TerminalThemeNotifier.auto
                            ? 'Matches the app · ${terminalTheme?.name ?? ''}'
                            : terminalTheme?.name ?? terminalId,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.go('/settings/themes'),
                    ),
                    const TextChoices(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Terminal',
                child: Column(
                  children: [
                    const TerminalChoices(),
                    SwitchListTile(
                      key: const Key('paste-warning'),
                      title: const Text('Check pastes of several lines'),
                      subtitle: const Text('Each line runs as a command, so see the text first.'),
                      value: ref.watch(pasteWarningProvider),
                      onChanged: (v) => ref.read(pasteWarningProvider.notifier).set(v),
                    ),
                    SwitchListTile(
                      key: const Key('program-clipboard'),
                      title: const Text('Let programs copy to the clipboard'),
                      subtitle: const Text('For tmux, vim and others (OSC 52).'),
                      value: ref.watch(programClipboardProvider),
                      onChanged: (v) => ref.read(programClipboardProvider.notifier).set(v),
                    ),
                    if (isTouchPlatform) ...[
                      Divider(height: 1, color: t.border),
                      ListTile(
                        key: const Key('keyboard-bar-settings'),
                        title: const Text('Keyboard bar'),
                        subtitle: const Text('The extra keys above the on-screen keyboard.'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/settings/keyboard-bar'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _Section(title: 'Hardware keyboard', child: HardwareKeyboardChoices()),
              const SizedBox(height: 16),
              _Section(
                title: 'Security',
                child: Column(
                  children: [
                    if (secrets != SecretsState.encrypted) ...[
                      ListTile(
                        key: const Key('secrets-state'),
                        leading: Icon(
                          secrets == SecretsState.locked ? Icons.lock_outline : Icons.lock_open_outlined,
                          color: t.muted,
                        ),
                        title: Text(
                          secrets == SecretsState.locked
                              ? 'Saved passwords and keys are locked'
                              : 'Your data on this device is not encrypted',
                        ),
                        subtitle: Text(
                          secrets == SecretsState.locked
                              ? "Promptly can't reach your system's secure storage, so saved hosts, passwords and keys can't be opened, and anything new is lost when Promptly closes. Unlock your keychain or allow Promptly when asked, then restart it."
                              : 'No keyring was found, so only file permissions protect your data. Install one, such as GNOME Keyring or KWallet, then restart Promptly.',
                        ),
                      ),
                      Divider(height: 1, color: t.border),
                    ],
                    const LockSettingsCard(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Hosts',
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const Key('reachability-check'),
                      title: const Text('Show which hosts are up'),
                      subtitle: const Text('Checks each host\'s port once a minute. Nothing else is sent.'),
                      value: ref.watch(reachabilityProvider),
                      onChanged: (v) => ref.read(reachabilityProvider.notifier).set(v),
                    ),
                    ListTile(
                      key: const Key('settings-session-labels'),
                      leading: Icon(Icons.label_outline, color: t.muted),
                      title: const Text('Session labels'),
                      subtitle: const Text('Coloured bars such as Production, so you know which box you are on.'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.go('/settings/session-labels'),
                    ),
                    ListTile(
                      key: const Key('import-csv'),
                      leading: Icon(Icons.table_chart_outlined, color: t.muted),
                      title: const Text('Import from a CSV file'),
                      subtitle: const Text('From Termius, or any file with a Hostname column.'),
                      trailing: TextButton(onPressed: () => showCsvImport(context, ref), child: const Text('Import')),
                    ),
                    if (supportsLocalShell)
                      ListTile(
                        key: const Key('import-ssh-config'),
                        leading: Icon(Icons.file_download_outlined, color: t.muted),
                        title: const Text('Import from ~/.ssh/config'),
                        subtitle: const Text('Hosts, users, ports, jump hosts and keys.'),
                        trailing: TextButton(
                          onPressed: () => showSshConfigImport(context, ref),
                          child: const Text('Import'),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Sync',
                child: ListTile(
                  key: const Key('settings-sync'),
                  leading: Icon(
                    sync != null && sync.configured && sync.lastError == null
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: sync != null && sync.configured && sync.lastError == null ? t.accent : t.muted,
                  ),
                  title: Text(syncSummary(sync)),
                  subtitle: Text(
                    sync != null && sync.configured
                        ? (sync.location ?? '')
                        : 'Share your hosts across devices, using storage you already have.',
                  ),
                  trailing: TextButton(
                    onPressed: () => context.go('/settings/sync'),
                    child: Text(sync != null && sync.configured ? 'Open' : 'Set up'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'About',
                child: Column(
                  children: [
                    if (updateChecksSupported)
                      SwitchListTile(
                        key: const Key('update-check'),
                        title: const Text('Check for updates'),
                        subtitle: const Text('Asks GitHub once a day.'),
                        value: ref.watch(updateCheckProvider),
                        onChanged: (v) => ref.read(updateCheckProvider.notifier).set(v),
                      ),
                    ListTile(
                      key: const Key('settings-help'),
                      leading: Icon(Icons.help_outline, color: t.muted),
                      title: const Text('Help'),
                      subtitle: const Text('Getting started and keyboard shortcuts.'),
                      trailing: Icon(Icons.chevron_right, color: t.muted),
                      onTap: () => context.go('/settings/help'),
                    ),
                    ListTile(
                      key: const Key('settings-about'),
                      leading: Icon(Icons.info_outline, color: t.muted),
                      title: const Text('About Promptly'),
                      subtitle: Text('Version $appVersion'),
                      trailing: Icon(Icons.chevron_right, color: t.muted),
                      onTap: () => context.go('/settings/about'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Text sizes offered in Settings; zooming can land between them.
const fontSizeChoices = [10.0, 12.0, 13.0, 14.0, 16.0, 18.0, 20.0, 24.0, 28.0];

/// The terminal's font, text size and ligatures, in the Appearance section.
class TextChoices extends ConsumerWidget {
  const TextChoices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontSize = ref.watch(fontSizeProvider);
    final family = ref.watch(fontFamilyProvider);
    return Column(
      children: [
        ListTile(
          key: const Key('terminal-font'),
          title: const Text('Font'),
          subtitle: Text(family.isEmpty ? '${PromptlyTokens.monoFamily}, built in' : family),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/settings/fonts'),
        ),
        _ChoiceTile<double>(
          key: const Key('font-size'),
          title: 'Text size',
          description: 'Zooming in a session (Ctrl and + or −) changes it too.',
          value: fontSize,
          choices: {
            for (final size in {...fontSizeChoices, fontSize}.toList()..sort())
              size: size == FontSizeNotifier.normal ? '${size.round()} (default)' : '${size.round()}',
          },
          onChanged: (v) {
            ref.read(fontSizeProvider.notifier).set(v);
            ref.read(sessionManagerProvider.notifier).applyFontSize(v);
          },
        ),
        SwitchListTile(
          key: const Key('ligatures'),
          title: const Text('Ligatures'),
          subtitle: const Text('Shows pairs such as -> and != as one symbol, in fonts that have them.'),
          value: ref.watch(ligaturesProvider),
          onChanged: (v) => ref.read(ligaturesProvider.notifier).set(v),
        ),
      ],
    );
  }
}

/// The bell, scrollback and keyboard suggestions, in the Terminal section.
class TerminalChoices extends ConsumerWidget {
  const TerminalChoices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _ChoiceTile<BellMode>(
          key: const Key('bell'),
          title: 'Bell',
          description: 'When a program rings the bell. Vibrate is for phones and tablets.',
          value: ref.watch(bellProvider),
          choices: const {
            BellMode.flash: 'Flash the screen',
            BellMode.vibrate: 'Vibrate',
            BellMode.off: 'Do nothing',
          },
          onChanged: (v) => ref.read(bellProvider.notifier).set(v),
        ),
        _ChoiceTile<int>(
          key: const Key('scrollback'),
          title: 'Scrollback',
          description: 'Lines kept for scrolling back. Applies to new sessions.',
          value: ref.watch(scrollbackProvider),
          choices: {
            for (final lines in ScrollbackNotifier.choices)
              lines: lines == 10000 ? '${_thousands(lines)} (default)' : _thousands(lines),
          },
          onChanged: (v) => ref.read(scrollbackProvider.notifier).set(v),
        ),
        if (isTouchPlatform)
          SwitchListTile(
            key: const Key('autocorrect'),
            title: const Text('Autocorrect and suggestions'),
            subtitle: const Text('Off, what you type is sent exactly as typed.'),
            value: ref.watch(autocorrectProvider),
            onChanged: (v) => ref.read(autocorrectProvider.notifier).set(v),
          ),
      ],
    );
  }
}

/// What a keyboard plugged in or paired does in the terminal. Cmd as Ctrl
/// and Option as Alt show on iPad and Mac only, which have those keys.
class HardwareKeyboardChoices extends ConsumerWidget {
  const HardwareKeyboardChoices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        SwitchListTile(
          key: const Key('caps-lock-escape'),
          title: const Text('Caps Lock types Escape'),
          subtitle: const Text('Handy in vim. Use Shift for capitals.'),
          value: ref.watch(capsLockEscapeProvider),
          onChanged: (v) => ref.read(capsLockEscapeProvider.notifier).set(v),
        ),
        if (isApplePlatform)
          SwitchListTile(
            key: const Key('cmd-as-ctrl'),
            title: const Text('Cmd works as Ctrl'),
            subtitle: const Text('Copy and paste become Cmd+Shift+C and Cmd+Shift+V.'),
            value: ref.watch(cmdAsCtrlProvider),
            onChanged: (v) => ref.read(cmdAsCtrlProvider.notifier).set(v),
          ),
        if (isApplePlatform)
          SwitchListTile(
            key: const Key('option-as-meta'),
            title: const Text('Option works as Alt'),
            subtitle: const Text('For Alt shortcuts, as in emacs. Off, Option types special characters.'),
            value: ref.watch(optionAsMetaProvider),
            onChanged: (v) => ref.read(optionAsMetaProvider.notifier).set(v),
          ),
      ],
    );
  }
}

/// 100000 as "100,000".
String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// A setting with a few choices: the title, what it does, and a dropdown
/// under them that takes the full width, so long labels and large text
/// wrap instead of overflowing.
class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final String title;
  final String description;
  final T value;
  final Map<T, String> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(description),
          DropdownButton<T>(
            isExpanded: true,
            value: value,
            items: [
              for (final e in choices.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
          ),
        ),
        Card(child: child),
      ],
    );
  }
}
