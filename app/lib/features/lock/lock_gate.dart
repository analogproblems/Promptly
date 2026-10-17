import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import 'app_lock.dart';

/// Sits over the whole app: the lock screen while locked, the app passcode
/// prompt when one is asked for, and the watch on the app leaving and
/// coming back that decides when to lock.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final lock = ref.read(appLockProvider.notifier);
    switch (s) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        lock.wentAway();
      case AppLifecycleState.resumed:
        lock.cameBack();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appLockProvider);
    final request = state.passcodeRequest;
    return Stack(
      children: [
        // Locked, the app underneath is neither shown nor reachable.
        Offstage(offstage: state.locked && state.canCheck, child: TickerMode(enabled: !state.locked, child: widget.child)),
        if (state.locked && state.canCheck) const _LockScreen(),
        // Above the app's navigator, so it brings its own overlay for the
        // text field.
        if (request != null)
          Overlay(
            key: ObjectKey(request),
            initialEntries: [OverlayEntry(builder: (_) => _PasscodePrompt(request: request))],
          ),
      ],
    );
  }
}

class _LockScreen extends ConsumerStatefulWidget {
  const _LockScreen();

  @override
  ConsumerState<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<_LockScreen> {
  @override
  void initState() {
    super.initState();
    // Ask straight away; the button is for after a cancel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(appLockProvider.notifier).unlockApp();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.background,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 48, color: t.accent),
              const SizedBox(height: 16),
              Text('Promptly is locked', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.text)),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('unlock-app'),
                autofocus: true,
                onPressed: () => ref.read(appLockProvider.notifier).unlockApp(),
                icon: const Icon(Icons.lock_open),
                label: const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PasscodePrompt extends ConsumerStatefulWidget {
  const _PasscodePrompt({required this.request});

  final PasscodeRequest request;

  @override
  ConsumerState<_PasscodePrompt> createState() => _PasscodePromptState();
}

class _PasscodePromptState extends ConsumerState<_PasscodePrompt> {
  final _controller = TextEditingController();
  bool _wrong = false;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await ref.read(appLockProvider.notifier).submitPasscode(_controller.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _wrong = !ok;
      if (!ok) _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(widget.request.reason, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: t.text)),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('app-passcode'),
                    controller: _controller,
                    autofocus: true,
                    obscureText: true,
                    style: monoStyle(context, size: 15),
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'App passcode',
                      errorText: _wrong ? 'That is not the passcode.' : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => ref.read(appLockProvider.notifier).cancelPasscode(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('app-passcode-ok'),
                        onPressed: _busy ? null : _submit,
                        child: const Text('Unlock'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

