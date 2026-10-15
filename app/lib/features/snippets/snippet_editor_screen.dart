import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import 'models.dart';
import 'repositories.dart';

/// Create or edit a snippet. The variables section follows the command as
/// it is typed: every `{{name}}` gets a default and a prompt.
class SnippetEditorScreen extends ConsumerStatefulWidget {
  const SnippetEditorScreen({super.key, this.snippetId});

  final String? snippetId;

  @override
  ConsumerState<SnippetEditorScreen> createState() => _SnippetEditorScreenState();
}

class _SnippetEditorScreenState extends ConsumerState<SnippetEditorScreen> {
  final _form = GlobalKey<FormState>();
  late final Snippet _original;
  late final TextEditingController _label;
  late final TextEditingController _command;
  late final TextEditingController _tags;
  final Map<String, TextEditingController> _defaults = {};
  final Map<String, TextEditingController> _prompts = {};
  List<String> _names = const [];

  bool get _isNew => widget.snippetId == null;

  @override
  void initState() {
    super.initState();
    _original = ref.read(snippetsProvider.notifier).byId(widget.snippetId) ?? Snippet.create();
    _label = TextEditingController(text: _original.label);
    _command = TextEditingController(text: _original.command);
    _tags = TextEditingController(text: _original.tags.join(', '));
    for (final v in _original.variables) {
      _defaults[v.name] = TextEditingController(text: v.defaultValue ?? '');
      _prompts[v.name] = TextEditingController(text: v.prompt);
    }
    _names = Snippet.variableNames(_original.command);
  }

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    _tags.dispose();
    for (final c in [..._defaults.values, ..._prompts.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onCommandChanged(String text) {
    final names = Snippet.variableNames(text);
    if (names.join('\n') != _names.join('\n')) setState(() => _names = names);
  }

  TextEditingController _field(Map<String, TextEditingController> map, String name) =>
      map.putIfAbsent(name, TextEditingController.new);

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final label = _label.text.trim().isEmpty ? _command.text.trim().split('\n').first : _label.text.trim();
    final snippet = _original.copyWith(
      label: label,
      command: _command.text,
      tags: [for (final t in _tags.text.split(',')) if (t.trim().isNotEmpty) t.trim()],
      variables: [
        for (final name in _names)
          SnippetVariable(
            name: name,
            defaultValue: _defaults[name]?.text.isNotEmpty == true ? _defaults[name]!.text : null,
            prompt: _prompts[name]?.text.trim() ?? '',
          ),
      ],
    );
    ref.read(snippetsProvider.notifier).save(snippet);
    context.go('/snippets');
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${_original.label}?'),
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
    if (ok == true && mounted) {
      ref.read(snippetsProvider.notifier).delete(_original.id);
      context.go('/snippets');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 56,
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: () => context.go('/snippets'),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _isNew ? 'New snippet' : 'Edit snippet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.text),
                ),
              ),
              FilledButton(key: const Key('snippet-save'), onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
        Expanded(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                TextFormField(
                  key: const Key('snippet-label'),
                  controller: _label,
                  style: monoStyle(context, size: 14),
                  decoration: const InputDecoration(labelText: 'Label', hintText: 'Disk space'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('snippet-command'),
                  controller: _command,
                  minLines: 2,
                  maxLines: 8,
                  style: monoStyle(context, size: 14),
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    hintText: 'df -h {{path}}',
                    helperText: 'Write {{name}} for the parts that change; you are asked for them when it runs.',
                    alignLabelWithHint: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Needed' : null,
                  onChanged: _onCommandChanged,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('snippet-tags'),
                  controller: _tags,
                  style: monoStyle(context, size: 14),
                  decoration: const InputDecoration(labelText: 'Tags', hintText: 'ops, docker', helperText: 'Separated by commas.'),
                ),
                if (_names.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6),
                    child: Text(
                      'VARIABLES',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
                    ),
                  ),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final name in _names) ...[
                            Text(name, style: monoStyle(context, size: 13, weight: FontWeight.w600, color: t.text)),
                            const SizedBox(height: 6),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    key: Key('var-default-$name'),
                                    controller: _field(_defaults, name),
                                    style: monoStyle(context, size: 14),
                                    decoration: const InputDecoration(labelText: 'Default'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextFormField(
                                    key: Key('var-prompt-$name'),
                                    controller: _field(_prompts, name),
                                    decoration: const InputDecoration(labelText: 'Prompt', hintText: 'Which folder?'),
                                  ),
                                ),
                              ],
                            ),
                            if (name != _names.last) const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                if (!_isNew) ...[
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(foregroundColor: t.danger),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete snippet'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
