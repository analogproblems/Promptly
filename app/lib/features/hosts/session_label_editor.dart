import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../sessions/status_dot.dart';
import 'host_colors.dart';
import 'models.dart';
import 'repositories.dart';
import 'session_labels.dart';

/// Edit a session label: its name, its colour and whether it warns. With
/// [isNew] the label is made on Save. Returns the label as saved, or null
/// when nothing was (or it was deleted).
Future<SessionLabel?> showSessionLabelEditor(BuildContext context, SessionLabel label, {bool isNew = false}) {
  return showDialog<SessionLabel>(
    context: context,
    builder: (ctx) => _SessionLabelEditor(label: label, isNew: isNew),
  );
}

class _SessionLabelEditor extends ConsumerStatefulWidget {
  const _SessionLabelEditor({required this.label, required this.isNew});

  final SessionLabel label;
  final bool isNew;

  @override
  ConsumerState<_SessionLabelEditor> createState() => _SessionLabelEditorState();
}

class _SessionLabelEditorState extends ConsumerState<_SessionLabelEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.label.name);
  late String _color = widget.label.color;
  late final TextEditingController _hex =
      TextEditingController(text: hostColorNames.contains(widget.label.color) ? '' : widget.label.color);
  late bool _warn = widget.label.warn;
  String? _nameError;
  String? _hexError;

  @override
  void dispose() {
    _name.dispose();
    _hex.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'Give the label a name.');
      return;
    }
    if (_hexError != null) return;
    final saved = widget.label.copyWith(name: _name.text.trim(), color: _color, warn: _warn);
    ref.read(sessionLabelsProvider.notifier).save(saved);
    Navigator.pop(context, saved);
  }

  void _typedHex(String text) {
    final colour = parseHexColor(text);
    setState(() {
      if (text.trim().isEmpty) {
        _hexError = null;
      } else if (colour == null) {
        _hexError = 'Six hex digits, such as #1F6FEB';
      } else {
        _hexError = null;
        _color = '#${text.trim().replaceFirst('#', '').toUpperCase()}';
      }
    });
  }

  Future<void> _delete() async {
    final count = ref.read(hostsProvider).where((h) => h.sessionLabelId == widget.label.id).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${widget.label.name}?'),
        content: Text(switch (count) {
          0 => 'No hosts use it.',
          1 => '1 host uses it. It stays, without a label.',
          final n => '$n hosts use it. They stay, without a label.',
        }),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('label-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // The hosts as they are now: sync may have changed or removed some
    // while the question was open, and those changes must stand.
    final hosts = ref.read(hostsProvider.notifier);
    for (final h in [for (final h in ref.read(hostsProvider)) if (h.sessionLabelId == widget.label.id) h]) {
      hosts.save(h.copyWith(sessionLabelId: null));
    }
    ref.read(sessionLabelsProvider.notifier).delete(widget.label.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final brightness = Theme.of(context).brightness;
    final name = _name.text.trim().isEmpty ? 'Label' : _name.text.trim();
    return AlertDialog(
      title: Text(widget.isNew ? 'New label' : 'Label'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SessionLabelBar(mark: SessionMark(name: name, text: name, color: _color, warn: _warn)),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('label-name'),
              controller: _name,
              autofocus: widget.isNew,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'Production, Staging, Customer…',
                helperText: 'The words on the bar, unless a host sets its own.',
                errorText: _nameError,
              ),
              onChanged: (_) => setState(() => _nameError = null),
            ),
            const SizedBox(height: 16),
            Text('Colour', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in hostColorNames)
                  InkWell(
                    key: Key('label-colour-$c'),
                    onTap: () => setState(() {
                      _color = c;
                      _hex.clear();
                      _hexError = null;
                    }),
                    borderRadius: BorderRadius.circular(8),
                    child: Semantics(
                      label: c,
                      selected: _color == c,
                      button: true,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: hostColor(c, brightness),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _color == c ? t.text : Colors.transparent, width: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('label-hex'),
              controller: _hex,
              style: monoStyle(context, size: 13),
              decoration: InputDecoration(
                labelText: 'Or your own colour',
                hintText: '#1F6FEB',
                errorText: _hexError,
              ),
              onChanged: _typedHex,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('label-warn'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Show a warning sign'),
              value: _warn,
              onChanged: (v) => setState(() => _warn = v),
            ),
            if (!widget.isNew) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('label-delete'),
                  style: TextButton.styleFrom(foregroundColor: t.danger),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete label'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('label-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// A small dot in a label's colour, for lists and menus.
class LabelDot extends StatelessWidget {
  const LabelDot({super.key, required this.color, this.size = 12});

  final String color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: labelColor(color, Theme.of(context).brightness), shape: BoxShape.circle),
      );
}
