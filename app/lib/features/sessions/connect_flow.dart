import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/engine/engine.dart';

/// One attempt to connect over SSH, as the UI sees it: the step reached,
/// any question waiting for an answer, and the outcome.
class ConnectFlow extends ChangeNotifier {
  ConnectFlow({required this.engine, required this.request, required this.unlock});

  final Engine engine;

  /// What was asked for. A key passphrase typed along the way is put in,
  /// so trying again or reconnecting does not ask for it again.
  SshConnectRequest request;

  /// Whether a key passphrase typed here can be saved with its key.
  bool canRememberPassphrase = false;

  /// Told about every key passphrase typed, and whether to remember it.
  void Function(String passphrase, bool remember)? onKeyPassphrase;

  /// Asked before connecting when the request carries a private key: the
  /// app's fingerprint, face, PIN or passcode check. False stops here.
  /// Required, so no caller that connects can leave the check out.
  final Future<bool> Function() unlock;

  /// Waiting for [unlock].
  bool unlocking = false;

  int? _attemptId;
  StreamSubscription<SshEvent>? _sub;

  SshStep? step;
  final List<SshStep> completed = [];

  /// Questions waiting for the person. At most one is set at a time.
  SshHostKey? hostKey;
  String? secretPrompt;

  /// The secret asked for is a private key's passphrase.
  bool secretForKey = false;
  ({String name, String instructions, List<SshKbPrompt> prompts})? keyboard;

  int? sessionId;

  /// Why it failed: the technical reason, then the same in plain words
  /// with what to try (null when the engine had none to give).
  String? error;
  String? errorTitle;
  String? errorHint;
  bool cancelled = false;

  bool get finished => sessionId != null || error != null || cancelled;

  bool _started = false;

  /// Whether connecting uses a private key, here or on a jump host.
  bool get usesKey =>
      request.privateKey != null || request.jumps.any((j) => j.privateKey != null);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (usesKey) {
      unlocking = true;
      notifyListeners();
      final ok = await unlock();
      unlocking = false;
      if (cancelled || _disposed) return;
      if (!ok) {
        error = 'Your SSH key stays locked, so Promptly did not connect. Try again to unlock it.';
        notifyListeners();
        return;
      }
      notifyListeners();
    }
    try {
      _attemptId = engine.sshConnectBegin(request);
      _sub = engine.sshConnectEvents(_attemptId!).listen(
        _onEvent,
        onError: (Object e) {
          error = e is String ? e : e.toString();
          notifyListeners();
        },
      );
    } catch (e) {
      error = e is String ? e : e.toString();
      notifyListeners();
    }
  }

  void _onEvent(SshEvent e) {
    switch (e.kind) {
      case SshEventKind.progress:
        // The same step again (a jump host reporting its own progress) is
        // still in progress, not done.
        if (step != null && step != e.step && !completed.contains(step)) completed.add(step!);
        step = e.step;
      case SshEventKind.hostKey:
        hostKey = e.hostKey;
      case SshEventKind.secret:
        secretPrompt = e.secretPrompt;
        secretForKey = e.secretForKey;
      case SshEventKind.keyboardInteractive:
        keyboard = (
          name: e.kbName ?? '',
          instructions: e.kbInstructions ?? '',
          prompts: e.kbPrompts ?? const [],
        );
      case SshEventKind.connected:
        if (step != null && !completed.contains(step)) completed.add(step!);
        sessionId = e.sessionId;
      case SshEventKind.failed:
        error = e.error ?? 'The connection failed.';
        errorTitle = e.errorTitle;
        errorHint = e.errorHint;
    }
    notifyListeners();
  }

  void answerHostKey(bool trust) {
    hostKey = null;
    _call(() => engine.sshAnswerHostKey(_attemptId!, trust));
    notifyListeners();
  }

  /// Answer the secret question; `null` cancels. For a key passphrase,
  /// [remember] asks for it to be saved with the key.
  void answerSecret(String? secret, {bool remember = false}) {
    if (secret != null && secretForKey) onKeyPassphrase?.call(secret, remember);
    secretPrompt = null;
    secretForKey = false;
    _call(() => engine.sshAnswerSecret(_attemptId!, secret));
    notifyListeners();
  }

  void answerKeyboard(List<String>? answers) {
    keyboard = null;
    _call(() => engine.sshAnswerKeyboardInteractive(_attemptId!, answers));
    notifyListeners();
  }

  void cancel() {
    if (finished) return;
    cancelled = true;
    if (_attemptId != null) _call(() => engine.sshCancel(_attemptId!));
    notifyListeners();
  }

  /// Hang up a connection that worked but that nobody will use, as after
  /// a test.
  void discard() {
    if (_discarded || sessionId == null || _attemptId == null) return;
    _discarded = true;
    _call(() => engine.sshCancel(_attemptId!));
  }

  bool _discarded = false;

  void _call(void Function() f) {
    try {
      f();
    } catch (_) {
      // The attempt already ended; the stream carries the outcome.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }

  bool _disposed = false;
}
