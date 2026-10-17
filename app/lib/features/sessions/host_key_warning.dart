import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';

/// The full-screen stop for a server whose host key has changed.
///
/// Leaving is the big button. Trusting the new key takes two deliberate
/// steps (open "I know why it changed", tick that the fingerprint was
/// checked), so it cannot happen by a stray tap or a reflexive Enter.
/// Back, Escape and closing the page all count as leaving.
///
/// Pops with true to trust the new key, false to disconnect.
class HostKeyChangedPage extends StatefulWidget {
  const HostKeyChangedPage({super.key, required this.hostKey});

  final SshHostKey hostKey;

  @override
  State<HostKeyChangedPage> createState() => _HostKeyChangedPageState();
}

class _HostKeyChangedPageState extends State<HostKeyChangedPage> {
  bool _override = false;
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final k = widget.hostKey;
    final where = k.port == 22 ? k.host : '${k.host} port ${k.port}';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false);
      },
      // Escape leaves, like Back.
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(false)},
        child: Scaffold(
          backgroundColor: t.background,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.gpp_bad_outlined, size: 56, color: t.danger),
                      const SizedBox(height: 16),
                      Semantics(
                        header: true,
                        child: Text(
                          'Warning: the server\'s identity has changed',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: t.danger),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '$where showed a different host key from the one Promptly trusted before.',
                        style: TextStyle(fontSize: 16, height: 1.45, color: t.text),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Sometimes this is harmless: the server was reinstalled, replaced, or now uses a different '
                        'kind of key. It can also mean that someone between you and the server is pretending to be '
                        'it, to read what you type, passwords included. Promptly cannot tell these apart. Whoever '
                        'runs the server can.',
                        style: TextStyle(fontSize: 14, height: 1.5, color: t.muted),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'NEW KEY · ${k.algorithm} ${k.bits}',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
                      ),
                      const SizedBox(height: 6),
                      SelectableText(k.fingerprint, style: monoStyle(context, size: 18, color: t.text)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: t.surface,
                          border: Border.all(color: t.border),
                          borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                        ),
                        child: Text(k.randomart, style: monoStyle(context, size: 12, color: t.muted)),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: const Key('hostkey-disconnect'),
                          autofocus: true,
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Disconnect')),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (!_override)
                        Center(
                          child: TextButton(
                            key: const Key('hostkey-override'),
                            onPressed: () => setState(() => _override = true),
                            child: Text('I know why it changed…', style: TextStyle(color: t.muted)),
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            border: Border.all(color: t.danger),
                            borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CheckboxListTile(
                                key: const Key('hostkey-checked'),
                                contentPadding: EdgeInsets.zero,
                                controlAffinity: ListTileControlAffinity.leading,
                                value: _checked,
                                onChanged: (v) => setState(() => _checked = v ?? false),
                                title: Text(
                                  'I checked this fingerprint with whoever runs the server, and it matches.',
                                  style: TextStyle(fontSize: 14, color: t.text),
                                ),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton(
                                key: const Key('hostkey-trust'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: t.danger,
                                  side: BorderSide(color: _checked ? t.danger : t.border),
                                ),
                                onPressed: _checked ? () => Navigator.of(context).pop(true) : null,
                                child: const Text('Trust the new key and connect'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stands in the connection steps while [HostKeyChangedPage] is up, and
/// opens it as soon as it appears.
class ChangedHostKeyPanel extends StatefulWidget {
  const ChangedHostKeyPanel({super.key, required this.hostKey, required this.onAnswer});

  final SshHostKey hostKey;
  final void Function(bool) onAnswer;

  @override
  State<ChangedHostKeyPanel> createState() => _ChangedHostKeyPanelState();
}

class _ChangedHostKeyPanelState extends State<ChangedHostKeyPanel> {
  Route<bool>? _route;
  NavigatorState? _navigator;
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted || _route != null || _answered) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => HostKeyChangedPage(hostKey: widget.hostKey),
    );
    _navigator = navigator;
    _route = route;
    final trust = await navigator.push(route);
    _route = null;
    // Null: the page went away because the question did (the connection
    // was cancelled), not because the person answered.
    if (trust == null || _answered || !mounted) return;
    _answered = true;
    widget.onAnswer(trust);
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null && route.isActive) _navigator?.removeRoute(route);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.danger, width: 1.5),
        borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_bad_outlined, color: t.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This server\'s key has changed',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () {
                  _answered = true;
                  widget.onAnswer(false);
                },
                child: const Text('Disconnect'),
              ),
              OutlinedButton(onPressed: _open, child: const Text('Show the warning')),
            ],
          ),
        ],
      ),
    );
  }
}
