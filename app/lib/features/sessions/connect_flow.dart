import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/engine/engine.dart';

/// One attempt to connect over SSH, as the UI sees it: the step reached,
/// any question waiting for an answer, and the outcome.
class ConnectFlow extends ChangeNotifier {
  ConnectFlow({required this.engine, required this.request});

  final Engine engine;
  final SshConnectRequest request;

  int? _attemptId;
  StreamSubscription<SshEvent>? _sub;

  SshStep? step;
  final List<SshStep> completed = [];

  /// Questions waiting for the person. At most one is set at a time.
  SshHostKey? hostKey;
  String? secretPrompt;
  ({String name, String instructions, List<SshKbPrompt> prompts})? keyboard;

  int? sessionId;
  String? error;
  bool cancelled = false;

  bool get finished => sessionId != null || error != null || cancelled;

  void start() {
    if (_attemptId != null) return;
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
        if (step != null && !completed.contains(step)) completed.add(step!);
        step = e.step;
      case SshEventKind.hostKey:
        hostKey = e.hostKey;
      case SshEventKind.secret:
        secretPrompt = e.secretPrompt;
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
    }
    notifyListeners();
  }

  void answerHostKey(bool trust) {
    hostKey = null;
    _call(() => engine.sshAnswerHostKey(_attemptId!, trust));
    notifyListeners();
  }

  void answerSecret(String? secret) {
    secretPrompt = null;
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

  void _call(void Function() f) {
    try {
      f();
    } catch (_) {
      // The attempt already ended; the stream carries the outcome.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
