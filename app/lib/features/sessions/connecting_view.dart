import 'package:flutter/material.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import 'connect_flow.dart';

/// What fills the terminal area while a connection is being made: the steps
/// so far, and whichever question is waiting. Lives in the terminal's own
/// colours so it reads as part of the session, not a dialog over it.
class ConnectingView extends StatelessWidget {
  const ConnectingView({super.key, required this.flow, required this.onCancel, required this.onRetry});

  final ConnectFlow flow;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: flow,
      builder: (context, _) {
        final t = context.tokens;
        return Container(
          color: t.background,
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Steps(flow: flow),
                  const SizedBox(height: 20),
                  if (flow.hostKey != null)
                    _HostKeyPanel(key_: flow.hostKey!, onAnswer: flow.answerHostKey)
                  else if (flow.secretPrompt != null)
                    _SecretPanel(prompt: flow.secretPrompt!, onAnswer: flow.answerSecret)
                  else if (flow.keyboard != null)
                    _KeyboardPanel(
                      name: flow.keyboard!.name,
                      instructions: flow.keyboard!.instructions,
                      prompts: flow.keyboard!.prompts,
                      onAnswer: flow.answerKeyboard,
                    )
                  else if (flow.error != null)
                    _ErrorPanel(message: flow.error!, onRetry: onRetry, onCancel: onCancel)
                  else if (!flow.finished)
                    TextButton(onPressed: onCancel, child: const Text('Cancel')),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String stepLabel(SshStep s) => switch (s) {
      SshStep.resolving => 'Resolving',
      SshStep.connecting => 'Connecting',
      SshStep.verifyingHostKey => 'Verifying host key',
      SshStep.authenticating => 'Authenticating',
      SshStep.openingShell => 'Opening shell',
      SshStep.connected => 'Connected',
    };

class _Steps extends StatelessWidget {
  const _Steps({required this.flow});
  final ConnectFlow flow;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shown = [...flow.completed, if (flow.step != null && !flow.completed.contains(flow.step)) flow.step!];
    final host = '${flow.request.user}@${flow.request.host}${flow.request.port == 22 ? '' : ':${flow.request.port}'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(host, style: monoStyle(context, size: 13, weight: FontWeight.w600, color: t.text)),
        const SizedBox(height: 10),
        for (final s in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: flow.completed.contains(s) || s == SshStep.connected
                      ? Icon(Icons.check, size: 14, color: t.accent)
                      : flow.error != null
                          ? Icon(Icons.close, size: 14, color: t.danger)
                          : SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: t.muted),
                            ),
                ),
                const SizedBox(width: 6),
                Text(
                  stepLabel(s),
                  style: monoStyle(context, size: 13, color: flow.completed.contains(s) ? t.muted : t.text),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.accent});
  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: accent ?? t.border, width: accent == null ? 1 : 1.5),
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
      ),
      child: child,
    );
  }
}

class _HostKeyPanel extends StatelessWidget {
  const _HostKeyPanel({required this.key_, required this.onAnswer});
  final SshHostKey key_;
  final void Function(bool) onAnswer;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final changed = key_.status == SshHostKeyStatus.changed;
    return _Panel(
      accent: changed ? t.danger : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(changed ? Icons.warning_amber_rounded : Icons.shield_outlined,
                  color: changed ? t.danger : t.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  changed ? 'This server\'s key has changed' : 'First time connecting to this server',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            changed
                ? 'The key for ${key_.host} is different from the one trusted before. That can mean the server was reinstalled, or that something between you and it is pretending to be the server. Do not continue unless you know why it changed.'
                : 'Promptly has not seen ${key_.host} before. Check the fingerprint against one you trust, for example from whoever set the server up. Once trusted, any change to this key will always warn you.',
            style: TextStyle(fontSize: 13, height: 1.45, color: t.muted),
          ),
          const SizedBox(height: 14),
          Text('${key_.algorithm} ${key_.bits}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted)),
          const SizedBox(height: 4),
          SelectableText(key_.fingerprint, style: monoStyle(context, size: 13, color: t.text)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: t.background,
              border: Border.all(color: t.border),
              borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
            ),
            child: Text(key_.randomart, style: monoStyle(context, size: 12, color: t.muted)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton(
                style: changed ? FilledButton.styleFrom(backgroundColor: t.danger) : null,
                onPressed: () => onAnswer(true),
                child: Text(changed ? 'Trust the new key anyway' : 'Trust this key and connect'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => onAnswer(false), child: const Text('Cancel')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SecretPanel extends StatefulWidget {
  const _SecretPanel({required this.prompt, required this.onAnswer});
  final String prompt;
  final void Function(String?) onAnswer;

  @override
  State<_SecretPanel> createState() => _SecretPanelState();
}

class _SecretPanelState extends State<_SecretPanel> {
  final _controller = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.prompt, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text)),
          const SizedBox(height: 10),
          TextField(
            key: const Key('secret-input'),
            controller: _controller,
            autofocus: true,
            obscureText: !_show,
            style: monoStyle(context, size: 14),
            onSubmitted: (v) => widget.onAnswer(v),
            decoration: InputDecoration(
              hintText: 'Password',
              suffixIcon: IconButton(
                tooltip: _show ? 'Hide' : 'Show',
                icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(onPressed: () => widget.onAnswer(_controller.text), child: const Text('Connect')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => widget.onAnswer(null), child: const Text('Cancel')),
            ],
          ),
        ],
      ),
    );
  }
}

class _KeyboardPanel extends StatefulWidget {
  const _KeyboardPanel({
    required this.name,
    required this.instructions,
    required this.prompts,
    required this.onAnswer,
  });
  final String name;
  final String instructions;
  final List<SshKbPrompt> prompts;
  final void Function(List<String>?) onAnswer;

  @override
  State<_KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends State<_KeyboardPanel> {
  late final List<TextEditingController> _controllers =
      List.generate(widget.prompts.length, (_) => TextEditingController());

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() => widget.onAnswer([for (final c in _controllers) c.text]);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.name.isNotEmpty ? widget.name : 'The server is asking',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.text),
          ),
          if (widget.instructions.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(widget.instructions.trim(), style: TextStyle(fontSize: 13, color: t.muted)),
          ],
          const SizedBox(height: 10),
          for (var i = 0; i < widget.prompts.length; i++) ...[
            TextField(
              controller: _controllers[i],
              autofocus: i == 0,
              obscureText: !widget.prompts[i].echo,
              style: monoStyle(context, size: 14),
              onSubmitted: (_) => i == widget.prompts.length - 1 ? _submit() : null,
              decoration: InputDecoration(hintText: widget.prompts[i].prompt.trim()),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          Row(
            children: [
              FilledButton(onPressed: _submit, child: const Text('Continue')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => widget.onAnswer(null), child: const Text('Cancel')),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry, required this.onCancel});
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return _Panel(
      accent: t.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: t.danger),
              const SizedBox(width: 8),
              Expanded(child: Text('Could not connect', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text))),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(message, style: TextStyle(fontSize: 13, height: 1.45, color: t.muted)),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: onCancel, child: const Text('Close')),
            ],
          ),
        ],
      ),
    );
  }
}
