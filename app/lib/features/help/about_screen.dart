import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/links.dart';
import '../../core/theme/tokens.dart';
import '../../core/version.dart';
import '../updates/update_panel.dart';
import '../updates/updates.dart';
import 'help_screen.dart';

/// Version, licence and where the project lives.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final engineVersion = ref.watch(engineProvider).version();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to settings',
          onPressed: () => context.go('/settings'),
        ),
        title: const Text('About'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Center(
            child: Image.asset('assets/icon/promptly.png', width: 96, height: 96, semanticLabel: 'The Promptly icon'),
          ),
          const SizedBox(height: 16),
          Text(
            'Promptly',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.5, color: t.text),
          ),
          const SizedBox(height: 4),
          Text(
            'Version $appVersion · engine $engineVersion',
            key: const Key('about-version'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: t.muted),
          ),
          const SizedBox(height: 16),
          Text(
            'Your terminal, everywhere. Your data, yours.\n\nFree and open source under the MIT licence. No servers, no accounts, no subscription: sync uses storage you already have, and nothing leaves this device unless you set that up.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.5, color: t.muted),
          ),
          const SizedBox(height: 24),
          if (updateChecksSupported) const HelpSection(title: 'Updates', children: [UpdatePanel()]),
          HelpSection(
            title: 'Project',
            children: [
              HelpLink(icon: Icons.menu_book_outlined, title: 'User guide', subtitle: AppLinks.guide, url: AppLinks.guide),
              HelpLink(icon: Icons.code_outlined, title: 'Source code', subtitle: AppLinks.source, url: AppLinks.source),
              HelpLink(icon: Icons.bug_report_outlined, title: 'Report a problem', subtitle: AppLinks.issues, url: AppLinks.issues),
              HelpLink(icon: Icons.privacy_tip_outlined, title: 'Privacy policy', subtitle: AppLinks.privacy, url: AppLinks.privacy),
            ],
          ),
          HelpSection(
            title: 'Legal',
            children: [
              ListTile(
                key: const Key('about-licences'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.description_outlined, color: t.muted),
                title: const Text('Licences'),
                subtitle: const Text('Promptly\'s MIT licence and the open-source parts it is built on'),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Promptly',
                  applicationVersion: appVersion,
                  applicationIcon: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Image.asset('assets/icon/promptly.png', width: 64, height: 64),
                  ),
                  applicationLegalese: 'MIT licence. Copyright (c) 2026 the Promptly authors.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
