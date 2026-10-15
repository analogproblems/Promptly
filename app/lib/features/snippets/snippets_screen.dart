import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import 'models.dart';
import 'repositories.dart';
import 'run_snippet.dart';

class SnippetsScreen extends ConsumerStatefulWidget {
  const SnippetsScreen({super.key});

  @override
  ConsumerState<SnippetsScreen> createState() => _SnippetsScreenState();
}

class _SnippetsScreenState extends ConsumerState<SnippetsScreen> {
  String _query = '';

  bool _matches(Snippet s) {
    if (_query.isEmpty) return true;
    return s.label.toLowerCase().contains(_query) ||
        s.command.toLowerCase().contains(_query) ||
        s.tags.any((t) => t.toLowerCase().contains(_query));
  }

  Future<void> _delete(Snippet s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${s.label}?'),
        content: const Text('The snippet is removed from every device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.tokens.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(snippetsProvider.notifier).delete(s.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final snippets = ref.watch(snippetsProvider);
    final shown = snippets.where(_matches).toList();

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.go('/snippets/new'),
        tooltip: 'Add snippet',
        child: const Icon(Icons.add),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Snippets'),
          if (snippets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                style: monoStyle(context, size: 14),
                decoration: InputDecoration(
                  hintText: 'Search snippets',
                  prefixIcon: Icon(Icons.search, color: t.muted),
                ),
              ),
            ),
          Expanded(
            child: snippets.isEmpty
                ? EmptyState(
                    icon: Icons.code_outlined,
                    title: 'No snippets yet',
                    message:
                        'Save the commands you type all the time. Write {{name}} for the parts that change and Promptly asks for them when the snippet runs.',
                    action: OutlinedButton.icon(
                      onPressed: () => context.go('/snippets/new'),
                      icon: const Icon(Icons.add),
                      label: const Text('New snippet'),
                    ),
                  )
                : shown.isEmpty
                    ? EmptyState(
                        icon: Icons.search_off,
                        title: 'No snippets match',
                        message: 'Nothing matches "$_query".',
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                        children: [
                          for (final s in shown)
                            _SnippetRow(
                              snippet: s,
                              onRun: () => runSnippetInSession(context, ref, s),
                              onRunOnHosts: () => context.go('/snippets/${s.id}/run'),
                              onEdit: () => context.go('/snippets/${s.id}'),
                              onDelete: () => _delete(s),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _SnippetRow extends StatelessWidget {
  const _SnippetRow({
    required this.snippet,
    required this.onRun,
    required this.onRunOnHosts,
    required this.onEdit,
    required this.onDelete,
  });

  final Snippet snippet;
  final VoidCallback onRun;
  final VoidCallback onRunOnHosts;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      key: Key('snippet-row-${snippet.id}'),
      onTap: onRun,
      borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.border),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.code, size: 18, color: t.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          snippet.label,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(context, size: 14, weight: FontWeight.w600, color: t.text),
                        ),
                      ),
                      for (final tag in snippet.tags.take(3)) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(color: t.border),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(tag, style: TextStyle(fontSize: 10, color: t.muted)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    snippet.firstLine,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(context, size: 12, color: t.muted),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Snippet actions',
              onSelected: (v) {
                switch (v) {
                  case 'run':
                    onRun();
                  case 'hosts':
                    onRunOnHosts();
                  case 'edit':
                    onEdit();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'run', child: Text('Run in a session')),
                PopupMenuItem(value: 'hosts', child: Text('Run on hosts…')),
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
