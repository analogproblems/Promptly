import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
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

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _pingController = TextEditingController();
  String? _pingReply;

  @override
  void dispose() {
    _pingController.dispose();
    super.dispose();
  }

  void _ping() {
    final reply = ref.read(engineProvider).ping(_pingController.text);
    setState(() => _pingReply = reply);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final engine = ref.watch(engineProvider);
    final themeMode = ref.watch(themeModeProvider);
    final terminalSetting = ref.watch(terminalThemeProvider);
    final terminalId = resolveTerminalTheme(terminalSetting, Theme.of(context).brightness);
    final themes = ref.watch(themesProvider);
    final sync = ref.watch(syncStatusProvider).value;
    final programClipboard = ref.watch(programClipboardProvider);
    final terminalTheme = themes.cast<ThemeInfo?>().firstWhere(
      (th) => th!.id == terminalId,
      orElse: () => themes.isEmpty ? null : themes.first,
    );

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
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Terminal',
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const Key('paste-warning'),
                      title: const Text('Show text before pasting several lines'),
                      subtitle: const Text(
                        'Each line of a paste runs as a command. On, you see the text and how many lines it has first.',
                      ),
                      value: ref.watch(pasteWarningProvider),
                      onChanged: (v) => ref.read(pasteWarningProvider.notifier).set(v),
                    ),
                    SwitchListTile(
                      key: const Key('program-clipboard'),
                      title: const Text('Let programs copy to the clipboard'),
                      subtitle: const Text(
                        'tmux, vim and others can set your clipboard (OSC 52). Off, a remote program cannot touch what you copied.',
                      ),
                      value: programClipboard,
                      onChanged: (v) => ref.read(programClipboardProvider.notifier).set(v),
                    ),
                    const TerminalChoices(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _Section(title: 'Security', child: LockSettingsCard()),
              const SizedBox(height: 16),
              _Section(
                title: 'Hosts',
                child: Column(
                  children: [
                    SwitchListTile(
                      key: const Key('reachability-check'),
                      title: const Text('Show which hosts are up'),
                      subtitle: const Text(
                        'A quick knock on each host\'s port once a minute, from this device. Nothing else is sent.',
                      ),
                      value: ref.watch(reachabilityProvider),
                      onChanged: (v) => ref.read(reachabilityProvider.notifier).set(v),
                    ),
                    ListTile(
                      key: const Key('import-csv'),
                      leading: Icon(Icons.table_chart_outlined, color: t.muted),
                      title: const Text('Import from a CSV file'),
                      subtitle: const Text('The file Termius exports, or any with a Hostname column.'),
                      trailing: TextButton(onPressed: () => showCsvImport(context, ref), child: const Text('Import')),
                    ),
                    if (supportsLocalShell)
                      ListTile(
                        key: const Key('import-ssh-config'),
                        leading: Icon(Icons.file_download_outlined, color: t.muted),
                        title: const Text('Import from ~/.ssh/config'),
                        subtitle: const Text('Hosts, users, ports, jump hosts and the keys they name.'),
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
                    sync == null || !sync.configured
                        ? Icons.cloud_off_outlined
                        : sync.lastError != null
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_done_outlined,
                    color: sync != null && sync.configured && sync.lastError == null ? t.accent : t.muted,
                  ),
                  title: Text(syncSummary(sync)),
                  subtitle: Text(
                    sync != null && sync.configured
                        ? (sync.location ?? '')
                        : 'The same hosts on every device, through storage you already have. Free.',
                  ),
                  trailing: TextButton(
                    onPressed: () => context.go('/settings/sync'),
                    child: Text(sync != null && sync.configured ? 'Open' : 'Set up'),
                  ),
                ),
              ),
              if (engine.secretsState() case final kept when kept != SecretsState.encrypted) ...[
                const SizedBox(height: 16),
                _Section(
                  title: 'Security',
                  child: ListTile(
                    key: const Key('secrets-state'),
                    leading: Icon(
                      kept == SecretsState.locked ? Icons.lock_outline : Icons.lock_open_outlined,
                      color: t.muted,
                    ),
                    title: Text(
                      kept == SecretsState.locked
                          ? 'Saved passwords and keys are locked'
                          : 'Your data on this device is not encrypted',
                    ),
                    subtitle: Text(
                      kept == SecretsState.locked
                          ? "Promptly couldn't get its key from your system's secure storage, so it can't use or save passwords and keys, and it can't open your saved hosts and settings. Anything you add now is kept only until Promptly closes. Unlock your keychain, or allow Promptly when asked, and restart Promptly."
                          : 'This computer has no keyring for Promptly to keep its key in, so only file permissions protect your hosts, settings, passwords and keys. Install one, such as GNOME Keyring or KWallet, and restart Promptly.',
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _Section(
                title: 'Engine',
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.memory_outlined, color: t.muted, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Rust engine ${engine.version()}',
                              style: monoStyle(context, size: 13, color: t.text),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Milestone 0 check: send a string through the engine and back.',
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('ping-input'),
                              controller: _pingController,
                              onSubmitted: (_) => _ping(),
                              style: monoStyle(context, size: 14),
                              decoration: const InputDecoration(hintText: 'Your name'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(onPressed: _ping, child: const Text('Ping')),
                        ],
                      ),
                      if (_pingReply != null) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Icon(Icons.check_circle_outline, color: t.accent, size: 18),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _pingReply!,
                                key: const Key('ping-reply'),
                                style: monoStyle(context, size: 13, color: t.text),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (updateChecksSupported) ...[
                const SizedBox(height: 16),
                _Section(
                  title: 'Updates',
                  child: SwitchListTile(
                    key: const Key('update-check'),
                    title: const Text('Check for updates automatically'),
                    subtitle: const Text(
                      'Asks GitHub once a day whether a new version is out. Off, Promptly only looks when you press Check on the About page.',
                    ),
                    value: ref.watch(updateCheckProvider),
                    onChanged: (v) => ref.read(updateCheckProvider.notifier).set(v),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _Section(
                title: 'Help',
                child: Column(
                  children: [
                    ListTile(
                      key: const Key('settings-help'),
                      leading: Icon(Icons.help_outline, color: t.muted),
                      title: const Text('Help'),
                      subtitle: const Text('Getting started, keyboard shortcuts, what the session bar does.'),
                      trailing: Icon(Icons.chevron_right, color: t.muted),
                      onTap: () => context.go('/settings/help'),
                    ),
                    ListTile(
                      key: const Key('settings-about'),
                      leading: Icon(Icons.info_outline, color: t.muted),
                      title: const Text('About Promptly'),
                      subtitle: Text('Version $appVersion · free and open source, MIT licensed.'),
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

/// The terminal's bell, text size and scrollback, in the Terminal section.
class TerminalChoices extends ConsumerWidget {
  const TerminalChoices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontSize = ref.watch(fontSizeProvider);
    return Column(
      children: [
        _ChoiceTile<BellMode>(
          key: const Key('bell'),
          title: 'Bell',
          description:
              'What happens when a program rings the bell. Vibrate works on phones and tablets; elsewhere the screen flashes.',
          value: ref.watch(bellProvider),
          choices: const {
            BellMode.flash: 'Flash the screen',
            BellMode.vibrate: 'Vibrate',
            BellMode.off: 'Do nothing',
          },
          onChanged: (v) => ref.read(bellProvider.notifier).set(v),
        ),
        _ChoiceTile<double>(
          key: const Key('font-size'),
          title: 'Text size',
          description: 'Zooming in a session (Ctrl and + or −) changes it too, and the last size is kept.',
          value: fontSize,
          choices: {
            for (final size in {...fontSizeChoices, fontSize}.toList()..sort())
              size: size == FontSizeNotifier.normal ? '${size.round()}, the usual size' : '${size.round()}',
          },
          onChanged: (v) {
            ref.read(fontSizeProvider.notifier).set(v);
            ref.read(sessionManagerProvider.notifier).applyFontSize(v);
          },
        ),
        _ChoiceTile<int>(
          key: const Key('scrollback'),
          title: 'Lines to keep for scrolling back',
          description: 'More lines use more memory. A change applies to sessions opened after it.',
          value: ref.watch(scrollbackProvider),
          choices: {
            for (final lines in ScrollbackNotifier.choices)
              lines: lines == 10000 ? '${_thousands(lines)}, the usual' : _thousands(lines),
          },
          onChanged: (v) => ref.read(scrollbackProvider.notifier).set(v),
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
