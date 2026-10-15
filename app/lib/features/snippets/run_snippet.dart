import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../sessions/session_manager.dart';
import 'models.dart';

/// Ask for a snippet's variables. Returns the values, an empty map when
/// the snippet has none, or null when cancelled.
Future<Map<String, String>?> askVariables(BuildContext context, Snippet snippet) async {
  final names = Snippet.variableNames(snippet.command);
  if (names.isEmpty) return const {};
  return showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _VariablesDialog(snippet: snippet, names: names),
  );
}

class _VariablesDialog extends StatefulWidget {
  const _VariablesDialog({required this.snippet, required this.names});

  final Snippet snippet;
  final List<String> names;

  @override
  State<_VariablesDialog> createState() => _VariablesDialogState();
}

class _VariablesDialogState extends State<_VariablesDialog> {
  late final Map<String, TextEditingController> _fields;

  @override
  void initState() {
    super.initState();
    _fields = {
      for (final name in widget.names)
        name: TextEditingController(
          text: widget.snippet.variables.where((v) => v.name == name).firstOrNull?.defaultValue ?? '',
        ),
    };
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _run() => Navigator.pop(context, {for (final e in _fields.entries) e.key: e.value.text});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      title: Text(widget.snippet.label),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.snippet.command, style: monoStyle(context, size: 12, color: t.muted)),
            const SizedBox(height: 12),
            for (final name in widget.names) ...[
              TextField(
                key: Key('var-$name'),
                controller: _fields[name],
                autofocus: name == widget.names.first,
                style: monoStyle(context, size: 14),
                decoration: InputDecoration(
                  labelText: name,
                  helperText: widget.snippet.variables.where((v) => v.name == name).firstOrNull?.prompt.trim().isNotEmpty ==
                          true
                      ? widget.snippet.variables.firstWhere((v) => v.name == name).prompt
                      : null,
                ),
                onSubmitted: (_) => _run(),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('snippet-run-go'), onPressed: _run, child: const Text('Run')),
      ],
    );
  }
}

/// Run a snippet in a live session: the one given, the only one open, or
/// one picked from a list. The command is pasted and followed by Enter.
Future<void> runSnippetInSession(BuildContext context, WidgetRef ref, Snippet snippet, {SessionEntry? session}) async {
  final manager = ref.read(sessionManagerProvider.notifier);
  var target = session;
  if (target == null) {
    final live = [for (final e in ref.read(sessionManagerProvider)) if (e.controller != null && !e.controller!.exited) e];
    if (live.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No live session. Open a host first, or run the snippet on hosts.')),
      );
      return;
    }
    target = live.length == 1 ? live.single : await _pickSession(context, live);
    if (target == null || !context.mounted) return;
  }
  final values = await askVariables(context, snippet);
  if (values == null || !context.mounted) return;
  final controller = manager.byId(target.id)?.controller;
  if (controller == null || controller.exited) return;
  controller.paste(snippet.render(values));
  controller.write(const [13]);
  if (session == null) context.go('/sessions/${target.id}');
}

Future<SessionEntry?> _pickSession(BuildContext context, List<SessionEntry> live) {
  return showDialog<SessionEntry>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Run in which session?'),
      children: [
        for (final e in live)
          SimpleDialogOption(
            key: Key('pick-session-${e.id}'),
            onPressed: () => Navigator.pop(ctx, e),
            child: Text(e.title, style: monoStyle(ctx, size: 13)),
          ),
      ],
    ),
  );
}
