import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../shell/empty_state.dart';
import '../terminal/keyboard_bar_keys.dart';

/// Which keys the keyboard bar carries, and in what order. The bar's keys
/// can be dragged into a new order (screen readers get Move up and Move
/// down actions), removed, or added from the rest.
class KeyboardBarScreen extends ConsumerWidget {
  const KeyboardBarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final shown = ref.watch(barLayoutProvider);
    final layout = ref.read(barLayoutProvider.notifier);
    final rest = [for (final k in barKeys) if (!shown.contains(k.id)) k];
    final keys = [for (final id in shown) ?barKeyById(id)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Keyboard bar',
          leading: IconButton(
            tooltip: 'Back to settings',
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.arrow_back),
          ),
          trailing: TextButton(
            key: const Key('kb-layout-reset'),
            onPressed: layout.reset,
            child: const Text('Use the usual keys'),
          ),
        ),
        Expanded(
          child: ReorderableListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            buildDefaultDragHandles: false,
            onReorderItem: layout.move,
            header: Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'The keys above the keyboard on a phone or tablet, from left to right. '
                'Drag a key by its handle to move it.',
                style: TextStyle(color: t.muted, fontSize: 13),
              ),
            ),
            footer: Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      'MORE KEYS',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
                    ),
                  ),
                  if (rest.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text('Every key is on the bar.', style: TextStyle(color: t.muted, fontSize: 13)),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final k in rest)
                          Semantics(
                            button: true,
                            label: 'Add ${k.spoken}',
                            excludeSemantics: true,
                            onTap: () => layout.add(k.id),
                            child: ActionChip(
                              key: Key('kb-layout-add-${k.id}'),
                              avatar: const Icon(Icons.add, size: 16),
                              label: Text(k.label, style: monoStyle(context, size: 13, color: t.text)),
                              tooltip: 'Add ${k.spoken}',
                              onPressed: () => layout.add(k.id),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            children: [
              for (final (i, k) in keys.indexed)
                Card(
                  key: ValueKey('kb-layout-${k.id}'),
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    leading: _KeyCap(k.label),
                    title: Text(k.spoken),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: Key('kb-layout-remove-${k.id}'),
                          tooltip: 'Remove ${k.spoken}',
                          onPressed: () => layout.remove(k.id),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            key: Key('kb-layout-handle-${k.id}'),
                            padding: const EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle, color: t.muted),
                          ),
                        ),
                      ],
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

/// A key as it looks on the bar.
class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ExcludeSemantics(
      child: Container(
        constraints: const BoxConstraints(minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: t.background,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
        ),
        // Centred within the minimum width, but no wider than the label.
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(label, style: monoStyle(context, size: 13, weight: FontWeight.w600, color: t.text)),
        ),
      ),
    );
  }
}
