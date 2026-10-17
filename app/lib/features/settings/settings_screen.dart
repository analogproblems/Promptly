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
                child: SwitchListTile(
                  key: const Key('program-clipboard'),
                  title: const Text('Let programs copy to the clipboard'),
                  subtitle: const Text(
                    'tmux, vim and others can set your clipboard (OSC 52). Off, a remote program cannot touch what you copied.',
                  ),
                  value: programClipboard,
                  onChanged: (v) => ref.read(programClipboardProvider.notifier).set(v),
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
