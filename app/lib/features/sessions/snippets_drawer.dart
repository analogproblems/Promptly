import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../snippets/models.dart';
import '../snippets/repositories.dart';
import '../snippets/run_snippet.dart';
import 'session_manager.dart';

/// The snippets, a tap away from the keyboard: pick one and it runs in
/// this session. The variables are asked for after the sheet closes, from
/// the session screen, which outlives it.
Future<void> showSnippetsDrawer(BuildContext context, WidgetRef ref, SessionEntry entry) async {
  final picked = await showModalBottomSheet<Snippet>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _SnippetsDrawer(),
  );
  if (picked == null || !context.mounted) return;
  await runSnippetInSession(context, ref, picked, session: entry);
}

class _SnippetsDrawer extends ConsumerStatefulWidget {
  const _SnippetsDrawer();

  @override
  ConsumerState<_SnippetsDrawer> createState() => _SnippetsDrawerState();
}

class _SnippetsDrawerState extends ConsumerState<_SnippetsDrawer> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final snippets = ref.watch(snippetsProvider);
    final shown = [
      for (final s in snippets)
        if (_query.isEmpty || s.label.toLowerCase().contains(_query) || s.command.toLowerCase().contains(_query)) s,
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Snippets', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.text)),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    context.go('/snippets/new');
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New'),
                ),
              ],
            ),
            if (snippets.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No snippets yet. Save the commands you type all the time and run them from here with one tap.',
                  style: TextStyle(fontSize: 13, color: t.muted),
                ),
              )
            else ...[
              TextField(
                autofocus: snippets.length > 6,
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                style: monoStyle(context, size: 14),
                decoration: InputDecoration(hintText: 'Search', prefixIcon: Icon(Icons.search, color: t.muted)),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final Snippet s in shown)
                      ListTile(
                        key: Key('drawer-snippet-${s.id}'),
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.code, color: t.accent, size: 20),
                        title: Text(s.label, style: monoStyle(context, size: 13, weight: FontWeight.w600, color: t.text)),
                        subtitle: Text(s.firstLine, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12, color: t.muted)),
                        trailing: s.hasVariables ? Icon(Icons.data_object, size: 16, color: t.muted) : null,
                        onTap: () => Navigator.pop(context, s),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
