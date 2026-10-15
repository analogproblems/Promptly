import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import 'host_colors.dart';
import 'models.dart';
import 'repositories.dart';

/// Edit a group: its name and colour, and the defaults its hosts inherit
/// when they leave a field blank.
Future<void> showGroupEditor(BuildContext context, WidgetRef ref, Group group) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _GroupEditor(group: group),
  );
}

class _GroupEditor extends ConsumerStatefulWidget {
  const _GroupEditor({required this.group});

  final Group group;

  @override
  ConsumerState<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends ConsumerState<_GroupEditor> {
  late final TextEditingController _label = TextEditingController(text: widget.group.label);
  late final TextEditingController _user =
      TextEditingController(text: widget.group.defaults['username'] as String? ?? '');
  late String? _color = widget.group.color;
  late String? _identityId = widget.group.defaults['identity_id'] as String?;

  @override
  void dispose() {
    _label.dispose();
    _user.dispose();
    super.dispose();
  }

  void _save() {
    final defaults = Map<String, dynamic>.from(widget.group.defaults);
    final user = _user.text.trim();
    if (user.isEmpty) {
      defaults.remove('username');
    } else {
      defaults['username'] = user;
    }
    if (_identityId == null) {
      defaults.remove('identity_id');
    } else {
      defaults['identity_id'] = _identityId;
    }
    ref.read(groupsProvider.notifier).save(Group(
          id: widget.group.id,
          label: _label.text.trim().isEmpty ? widget.group.label : _label.text.trim(),
          parentId: widget.group.parentId,
          color: _color,
          defaults: defaults,
        ));
    ref.invalidate(hostsProvider);
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${widget.group.label}?'),
        content: const Text('Its hosts stay, under Other.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final hosts = ref.read(hostsProvider.notifier);
    for (final h in ref.read(hostsProvider)) {
      if (h.groupId == widget.group.id) hosts.save(h.copyWith(groupId: null));
    }
    ref.read(groupsProvider.notifier).delete(widget.group.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final identities = ref.watch(identitiesProvider);
    final brightness = Theme.of(context).brightness;
    return AlertDialog(
      title: const Text('Group'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('group-label'),
              controller: _label,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            Text('Colour', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final name in hostColorNames)
                  InkWell(
                    onTap: () => setState(() => _color = name),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: hostColor(name, brightness).withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _color == name ? hostColor(name, brightness) : Colors.transparent, width: 2),
                      ),
                      child: Center(
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: hostColor(name, brightness), shape: BoxShape.circle),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('DEFAULTS FOR ITS HOSTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted)),
            const SizedBox(height: 4),
            Text('Used when a host leaves the field blank or asks each time.', style: TextStyle(fontSize: 12, color: t.muted)),
            const SizedBox(height: 8),
            TextField(
              key: const Key('group-user'),
              controller: _user,
              style: monoStyle(context, size: 13),
              decoration: const InputDecoration(labelText: 'User'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: const Key('group-key'),
              initialValue: _identityId,
              decoration: const InputDecoration(labelText: 'Key'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None')),
                for (final i in identities) DropdownMenuItem<String?>(value: i.id, child: Text(i.label)),
              ],
              onChanged: (v) => setState(() => _identityId = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: _delete,
          child: const Text('Delete group'),
        ),
        const Spacer(),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('group-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
