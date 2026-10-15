import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import 'settings_providers.dart';

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
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Theme', style: TextStyle(color: t.text)),
                      ),
                      SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: ThemeMode.system, label: Text('System')),
                          ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                          ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                        ],
                        selected: {themeMode},
                        onSelectionChanged: (s) =>
                            ref.read(themeModeProvider.notifier).set(s.first),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Sync',
                child: ListTile(
                  leading: Icon(Icons.cloud_off_outlined, color: t.muted),
                  title: const Text('Vault not set up'),
                  subtitle: const Text(
                    'Lands in milestone 2. Until then everything stays on this device.',
                  ),
                  trailing: TextButton(
                    onPressed: () => notYet(context, 'Sync setup lands in milestone 2.'),
                    child: const Text('Set up'),
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
                          Text(
                            'Rust engine ${engine.version()}',
                            style: monoStyle(context, size: 13, color: t.text),
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
              const SizedBox(height: 16),
              _Section(
                title: 'About',
                child: ListTile(
                  leading: Icon(Icons.info_outline, color: t.muted),
                  title: const Text('Promptly'),
                  subtitle: const Text(
                    'Free and open source, MIT licensed. No servers, no accounts, no subscription.',
                  ),
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
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: t.muted,
            ),
          ),
        ),
        Card(child: child),
      ],
    );
  }
}
