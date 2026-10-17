import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// What a paste of [text] would do: how many lines it holds and whether it
/// ends with a newline (which presses Enter on the last one).
({int lines, bool endsWithNewline}) describePaste(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final endsWithNewline = normalized.endsWith('\n');
  final body = endsWithNewline ? normalized.substring(0, normalized.length - 1) : normalized;
  return (lines: '\n'.allMatches(body).length + 1, endsWithNewline: endsWithNewline);
}

/// Whether pasting [text] needs a look first: anything with a newline in
/// it, since each newline runs what is before it.
bool pasteNeedsConfirm(String text) => text.contains('\n') || text.contains('\r');

/// Drop one final newline (and a carriage return before it).
String withoutFinalNewline(String text) {
  if (text.endsWith('\r\n')) return text.substring(0, text.length - 2);
  if (text.endsWith('\n') || text.endsWith('\r')) return text.substring(0, text.length - 1);
  return text;
}

/// Show what is about to be pasted and let the user paste it, paste it
/// without the final newline, or cancel. Returns the text to paste, or null.
///
/// With [warn] off, or for text without a newline, the text comes straight
/// back.
Future<String?> confirmPaste(BuildContext context, String text, {required bool warn}) async {
  if (!warn || !pasteNeedsConfirm(text)) return text;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => PasteSheet(text: text),
  );
}

class PasteSheet extends StatelessWidget {
  const PasteSheet({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final info = describePaste(text);
    final lineWord = info.lines == 1 ? 'line' : 'lines';
    final summary = info.endsWithNewline
        ? '${info.lines} $lineWord. Each line runs as you paste it, the last one too.'
        : '${info.lines} $lineWord. Every line but the last runs as you paste it.';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Paste this?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(summary, key: const Key('paste-summary'), style: TextStyle(color: t.muted)),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
              child: Container(
                decoration: BoxDecoration(
                  color: t.background,
                  border: Border.all(color: t.border),
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: TextStyle(fontFamily: PromptlyTokens.monoFamily, fontSize: 13, color: t.text),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                if (info.endsWithNewline)
                  OutlinedButton(
                    key: const Key('paste-no-newline'),
                    onPressed: () => Navigator.of(context).pop(withoutFinalNewline(text)),
                    child: const Text('Paste without final newline'),
                  ),
                FilledButton(
                  key: const Key('paste-confirm'),
                  onPressed: () => Navigator.of(context).pop(text),
                  child: const Text('Paste'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
