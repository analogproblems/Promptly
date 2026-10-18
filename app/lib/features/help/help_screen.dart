import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/links.dart';
import '../../core/platform.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/shell_scaffold.dart';
import '../workspace/app_shortcuts.dart';

/// In-app help: how to start, what the keys do, where to read more.
class HelpScreen extends ConsumerWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to settings',
          onPressed: () => context.go('/settings'),
        ),
        title: const Text('Help'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          const HelpSection(
            title: 'Getting started',
            children: [
              HelpStep(1, 'Add a host', 'Hosts, then the plus. Label, address, user and how to log in: a password, a key, or whatever the server asks.'),
              HelpStep(2, 'Connect', 'Tap the host. The first time, Promptly shows the server\'s key fingerprint and asks you to trust it.'),
              HelpStep(3, 'Keep a key', 'Keys generates an ed25519 key in one tap, or imports one you have. Copy the public half onto the server.'),
              HelpStep(4, 'Save a command', 'Snippets keep the commands you type all the time. Write {{name}} for the parts that change.'),
              HelpStep(5, 'Sync', 'Settings, then Sync. Pick a folder another device also sees, or a server over SFTP. Everything is encrypted before it leaves this device.'),
            ],
          ),
          if (ShellScaffold.isDesktopPlatform)
            HelpSection(
              title: 'Keyboard shortcuts',
              children: [
                // The keys column is as wide as its longest entry, so a
                // long chord never runs into its description.
                Table(
                  columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
                  children: [
                    for (final s in desktopShortcuts)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 5, bottom: 5, right: 20),
                            child: Text(s.keys, style: monoStyle(context, size: 12.5, color: t.text)),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Text(s.what, style: TextStyle(fontSize: 14, color: t.muted)),
                          ),
                        ],
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Plain Ctrl+D, Ctrl+W, Ctrl+T, Ctrl+B and Ctrl+K go to the program in the terminal, as they should.',
                    style: TextStyle(fontSize: 13, color: t.muted),
                  ),
                ),
              ],
            ),
          const HelpSection(
            title: 'In a session',
            children: [
              HelpTip(Icons.search, 'Search', 'The magnifier in the session bar (Ctrl+Shift+F on desktop) finds text in the screen and the scrollback. Enter walks up, Shift+Enter down.'),
              HelpTip(Icons.link, 'Links', 'Web addresses in the output are underlined. Ctrl+click or the right-click menu opens one.'),
              HelpTip(Icons.code, 'Snippets', 'The snippets button in the session bar runs one in this session, asking for its variables first.'),
              HelpTip(Icons.folder_open, 'Files', 'Files browses the server over the connection the session already has: upload, download, rename, delete, permissions.'),
              HelpTip(Icons.alt_route, 'Port forwards', 'Saved on the host, started with the session when marked so, and switched from the session bar.'),
              HelpTip(Icons.history, 'Persistent sessions', 'A host with the persistent switch on attaches to tmux on the server, so the work survives a dropped connection.'),
            ],
          ),
          HelpSection(
            title: 'More',
            children: [
              HelpLink(icon: Icons.menu_book_outlined, title: 'User guide', subtitle: 'Everything Promptly does, step by step', url: AppLinks.guide),
              HelpLink(icon: Icons.bug_report_outlined, title: 'Report a problem', subtitle: 'Issues on GitHub', url: AppLinks.issues),
              HelpLink(icon: Icons.code_outlined, title: 'Source code', subtitle: 'MIT licensed, open to read', url: AppLinks.source),
              HelpLink(icon: Icons.privacy_tip_outlined, title: 'Privacy', subtitle: 'Nothing leaves this device unless you set up sync', url: AppLinks.privacy),
              ListTile(
                key: const Key('help-tour'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.flag_outlined, color: t.muted),
                title: const Text('Show the welcome tour again'),
                onTap: () => context.push('/welcome'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The desktop shortcuts, in the order the help lists them.
final desktopShortcuts = <({String keys, String what})>[
  (keys: describeShortcut(AppShortcuts.palette), what: 'Command palette: hosts, snippets, themes, every action'),
  (keys: describeShortcut(AppShortcuts.newTab), what: 'New tab'),
  (keys: describeShortcut(AppShortcuts.closePane), what: 'Close the pane; the tab closes with its last pane'),
  (keys: '${describeShortcut(AppShortcuts.nextTab)} / ${describeShortcut(AppShortcuts.previousTab)}', what: 'Next or previous tab'),
  (keys: isApplePlatform ? 'Cmd+1 … Cmd+9' : 'Alt+1 … Alt+9', what: 'A particular tab'),
  (keys: '${describeShortcut(AppShortcuts.splitRight)} / ${describeShortcut(AppShortcuts.splitDown)}', what: 'Split the pane right or down'),
  (keys: 'Alt+Arrows', what: 'Move between panes'),
  (keys: describeShortcut(AppShortcuts.hostsPanel), what: 'Hosts panel, for dragging hosts onto panes'),
  (keys: describeShortcut(AppShortcuts.find), what: 'Find in the session'),
  (keys: '${describeShortcut(AppShortcuts.copy)} / ${describeShortcut(AppShortcuts.paste)}', what: 'Copy or paste'),
  (keys: 'Ctrl+= / Ctrl+- / Ctrl+0', what: 'Bigger, smaller or normal text'),
  (keys: 'Ctrl+click', what: 'Open a link in the output'),
  (keys: describeShortcut(AppShortcuts.quit), what: 'Quit'),
];

/// "Ctrl+Shift+P" for a shortcut.
String describeShortcut(SingleActivator s) {
  final parts = <String>[
    if (s.control) 'Ctrl',
    if (s.meta) isApplePlatform ? 'Cmd' : 'Meta',
    if (s.alt) 'Alt',
    if (s.shift) 'Shift',
  ];
  final key = s.trigger;
  final label = switch (key) {
    LogicalKeyboardKey.tab => 'Tab',
    LogicalKeyboardKey.arrowLeft => 'Left',
    LogicalKeyboardKey.arrowRight => 'Right',
    LogicalKeyboardKey.arrowUp => 'Up',
    LogicalKeyboardKey.arrowDown => 'Down',
    _ => key.keyLabel.toUpperCase(),
  };
  return [...parts, label].join('+');
}

class HelpSection extends StatelessWidget {
  const HelpSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: t.muted),
            ),
          ),
          Material(
            color: t.surface,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: t.border),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ],
      ),
    );
  }
}

class HelpStep extends StatelessWidget {
  const HelpStep(this.number, this.title, this.body, {super.key});

  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: t.accent.withValues(alpha: 0.18), shape: BoxShape.circle),
            child: Text('$number', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: t.accent)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.text)),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(fontSize: 14, height: 1.4, color: t.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HelpTip extends StatelessWidget {
  const HelpTip(this.icon, this.title, this.body, {super.key});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: t.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.text)),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(fontSize: 14, height: 1.4, color: t.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A row that opens a web page, saying where it goes.
class HelpLink extends StatelessWidget {
  const HelpLink({super.key, required this.icon, required this.title, required this.subtitle, required this.url});

  final IconData icon;
  final String title;
  final String subtitle;
  final String url;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: t.muted),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Icon(Icons.open_in_new, size: 18, color: t.muted),
      onTap: () async {
        final ok = await openExternalLink(url);
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
        }
      },
    );
  }
}
