import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/tokens.dart';
import '../sessions/sessions_screen.dart' show openLocalShell, supportsLocalShell;
import '../settings/settings_providers.dart' show SettingKeys;

/// Whether the welcome tour has been seen (or skipped). A store that cannot
/// be read counts as seen, so nobody is ever stuck on the tour.
class OnboardingNotifier extends Notifier<bool> {
  @override
  bool build() {
    try {
      final raw = ref.watch(engineProvider).settingGet(SettingKeys.onboardingDone);
      return raw != null && jsonDecode(raw) == true;
    } catch (_) {
      return true;
    }
  }

  void markDone() {
    state = true;
    try {
      ref.read(engineProvider).settingSet(SettingKeys.onboardingDone, jsonEncode(true));
    } catch (_) {}
  }
}

final onboardingDoneProvider = NotifierProvider<OnboardingNotifier, bool>(OnboardingNotifier.new);

/// Three screens on first run, each skippable: what Promptly is, where
/// its data lives, and a way to start. Help can show it again later.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  static const pageCount = 3;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish([String location = '/hosts']) {
    ref.read(onboardingDoneProvider.notifier).markDone();
    context.go(location);
  }

  void _localShell() {
    ref.read(onboardingDoneProvider.notifier).markDone();
    openLocalShell(context, ref);
  }

  void _next() {
    if (_page >= OnboardingScreen.pageCount - 1) {
      _finish();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToPage(_page + 1);
    } else {
      _controller.animateToPage(_page + 1, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final last = _page == OnboardingScreen.pageCount - 1;
    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
                    child: TextButton(
                      key: const Key('onboarding-skip'),
                      onPressed: _finish,
                      child: const Text('Skip'),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _controller,
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [
                      _Page(
                        key: const Key('onboarding-page-0'),
                        picture: Image.asset('assets/icon/promptly.png', width: 96, height: 96, semanticLabel: 'The Promptly icon'),
                        title: 'Your terminal, everywhere.',
                        body:
                            'Promptly is a terminal and SSH client for phone, tablet and desktop. Jump hosts, port forwards, sessions that survive a dropped connection, snippets, a file browser and scrollback search, all in one place.',
                      ),
                      _Page(
                        key: const Key('onboarding-page-1'),
                        picture: const _Tile(Icons.lock_outline),
                        title: 'Your data, yours.',
                        body:
                            'Hosts, keys and snippets live in an encrypted vault on storage you already own: a synced folder, or a server you have. No account, no servers, no subscription. Set up sync in Settings whenever you like.',
                      ),
                      _Page(
                        key: const Key('onboarding-page-2'),
                        picture: const _Tile(Icons.rocket_launch_outlined),
                        title: 'Ready when you are.',
                        body:
                            'Add a host, or open a local shell to try the terminal. Help in Settings has the keyboard shortcuts and a tour of the features.',
                        actions: [
                          OutlinedButton.icon(
                            key: const Key('onboarding-add-host'),
                            onPressed: () => _finish('/hosts/new'),
                            icon: const Icon(Icons.add),
                            label: const Text('Add a host'),
                          ),
                          if (supportsLocalShell)
                            OutlinedButton.icon(
                              key: const Key('onboarding-local-shell'),
                              onPressed: _localShell,
                              icon: const Icon(Icons.terminal),
                              label: const Text('Open a local shell'),
                            ),
                          OutlinedButton.icon(
                            key: const Key('onboarding-sync'),
                            onPressed: () => _finish('/settings/sync'),
                            icon: const Icon(Icons.sync),
                            label: const Text('Set up sync'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Semantics(
                  label: 'Page ${_page + 1} of ${OnboardingScreen.pageCount}',
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < OnboardingScreen.pageCount; i++)
                          AnimatedContainer(
                            duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: i == _page ? 22 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == _page ? t.accent : t.border,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: Key(last ? 'onboarding-start' : 'onboarding-next'),
                      onPressed: _next,
                      child: Text(last ? 'Get started' : 'Next'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({super.key, required this.picture, required this.title, required this.body, this.actions = const []});

  final Widget picture;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 24),
          picture,
          const SizedBox(height: 28),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: t.text),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, height: 1.5, color: t.muted),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 24),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: actions),
          ],
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Icon(icon, color: t.accent, size: 44),
    );
  }
}
