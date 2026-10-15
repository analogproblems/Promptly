import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import 'terminal_controller.dart';
import 'terminal_view.dart';

/// The row of keys a phone keyboard lacks, above the system keyboard: Esc,
/// Tab, sticky Ctrl and Alt, arrows, and the characters shells live on.
/// Every key has a label for screen readers.
class KeyboardBar extends StatelessWidget {
  const KeyboardBar({super.key, required this.controller, this.onSnippets});

  final TerminalController controller;
  final VoidCallback? onSnippets;

  static const height = 44.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final appCursor = controller.grid.appCursor;
        List<int> arrow(String letter) => [0x1b, appCursor ? 0x4f : 0x5b, letter.codeUnitAt(0)];
        final keys = <_BarKey>[
          _BarKey('esc', 'Esc', 'Escape', const [0x1b]),
          _BarKey('tab', 'Tab', 'Tab', const [0x09]),
          _BarKey('ctrl', 'Ctrl', 'Control, held for the next key', const [], sticky: controller.stickyCtrl),
          _BarKey('alt', 'Alt', 'Alt, held for the next key', const [], sticky: controller.stickyAlt),
          _BarKey('left', '←', 'Left arrow', arrow('D')),
          _BarKey('down', '↓', 'Down arrow', arrow('B')),
          _BarKey('up', '↑', 'Up arrow', arrow('A')),
          _BarKey('right', '→', 'Right arrow', arrow('C')),
          _BarKey('dash', '-', 'Dash', '-'.codeUnits),
          _BarKey('slash', '/', 'Slash', '/'.codeUnits),
          _BarKey('pipe', '|', 'Pipe', '|'.codeUnits),
          _BarKey('tilde', '~', 'Tilde', '~'.codeUnits),
          _BarKey('colon', ':', 'Colon', ':'.codeUnits),
          _BarKey('home', 'Home', 'Home', const [0x1b, 0x5b, 0x48]),
          _BarKey('end', 'End', 'End', const [0x1b, 0x5b, 0x46]),
          _BarKey('pgup', 'PgUp', 'Page up', const [0x1b, 0x5b, 0x35, 0x7e]),
          _BarKey('pgdn', 'PgDn', 'Page down', const [0x1b, 0x5b, 0x36, 0x7e]),
          _BarKey('del', 'Del', 'Delete', const [0x1b, 0x5b, 0x33, 0x7e]),
        ];
        return Container(
          height: height,
          decoration: BoxDecoration(
            color: t.surface,
            border: Border(top: BorderSide(color: t.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  children: [
                    for (final k in keys)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _KeyButton(k, onTap: () => _press(k)),
                      ),
                  ],
                ),
              ),
              if (onSnippets != null)
                IconButton(
                  key: const Key('kb-snippets'),
                  tooltip: 'Snippets',
                  visualDensity: VisualDensity.compact,
                  onPressed: onSnippets,
                  icon: const Icon(Icons.code, size: 20),
                ),
              IconButton(
                key: const Key('kb-keyboard'),
                tooltip: 'Hide the keyboard',
                visualDensity: VisualDensity.compact,
                onPressed: TerminalView.hideKeyboard,
                icon: const Icon(Icons.keyboard_hide_outlined, size: 20),
              ),
              const SizedBox(width: 4),
            ],
          ),
        );
      },
    );
  }

  void _press(_BarKey k) {
    switch (k.id) {
      case 'ctrl':
        controller.setSticky(ctrl: !controller.stickyCtrl);
        if (controller.stickyCtrl) HapticFeedback.selectionClick();
      case 'alt':
        controller.setSticky(alt: !controller.stickyAlt);
        if (controller.stickyAlt) HapticFeedback.selectionClick();
      default:
        // A character goes through the sticky modifiers (Ctrl+- and so on);
        // a sequence such as an arrow is sent as it is.
        if (k.bytes.length == 1 && k.bytes.first >= 0x20) {
          controller.write(controller.encodeTyped(String.fromCharCode(k.bytes.first)));
        } else {
          controller.write(k.bytes);
          if (controller.stickyCtrl || controller.stickyAlt) controller.setSticky(ctrl: false, alt: false);
        }
    }
  }
}

class _BarKey {
  const _BarKey(this.id, this.label, this.spoken, this.bytes, {this.sticky = false});

  final String id;
  final String label;
  final String spoken;
  final List<int> bytes;
  final bool sticky;
}

class _KeyButton extends StatelessWidget {
  const _KeyButton(this.k, {required this.onTap});

  final _BarKey k;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: k.spoken,
      selected: k.sticky,
      child: Material(
        key: Key('kb-${k.id}'),
        color: k.sticky ? t.accent : t.background,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Text(
              k.label,
              style: monoStyle(context, size: 13, weight: FontWeight.w600, color: k.sticky ? t.onAccent : t.text),
            ),
          ),
        ),
      ),
    );
  }
}
