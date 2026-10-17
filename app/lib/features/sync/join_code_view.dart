import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// How long the join code stays up (VAULT.md section 11).
const joinCodeShownFor = Duration(seconds: 60);

/// Show the join code, the QR code another device enrols with, over a
/// dimmed screen. It closes by itself after a minute, and as soon as the
/// app goes to the background, so it is never left up or caught in the
/// app switcher's picture.
Future<void> showJoinCode(BuildContext context, String payload) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      barrierLabel: 'Join code',
      pageBuilder: (_, _, _) => JoinCodeView(payload: payload),
    );

class JoinCodeView extends StatefulWidget {
  const JoinCodeView({super.key, required this.payload});

  /// The join code's text: what the QR code holds.
  final String payload;

  @override
  State<JoinCodeView> createState() => _JoinCodeViewState();
}

class _JoinCodeViewState extends State<JoinCodeView> with WidgetsBindingObserver {
  /// Seconds left. Counted by the ticks: the app is never in the
  /// background while this is up, so they keep time.
  int _left = joinCodeShownFor.inSeconds;
  Timer? _tick;
  bool _copied = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_left <= 1) {
        _close();
      } else {
        setState(() => _left--);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _close();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    _tick?.cancel();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final size = math.min(300.0, width - 72);
    const white = Colors.white;
    final dim = Colors.white.withValues(alpha: 0.75);
    return Material(
      key: const Key('join-code-view'),
      type: MaterialType.transparency,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Join code',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: white),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    color: white,
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(data: widget.payload, size: size),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Closes in $_left s',
                    key: const Key('join-code-countdown'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: white),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: size + 24,
                    child: LinearProgressIndicator(
                      value: _left / joinCodeShownFor.inSeconds,
                      color: white,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Whoever photographs or copies this code can read your vault. Show it only to your own device.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: white, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'On the other device, set up sync with the same folder or server and choose Use a join code. '
                    'Scanning is not available yet, so copy the code as text and paste it there.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: dim, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('join-code-copy'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: white,
                          side: const BorderSide(color: Colors.white54),
                        ),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: widget.payload));
                          if (mounted) setState(() => _copied = true);
                        },
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy as text'),
                      ),
                      FilledButton(
                        key: const Key('join-code-close'),
                        style: FilledButton.styleFrom(backgroundColor: white, foregroundColor: Colors.black),
                        onPressed: _close,
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                  if (_copied) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Copied. Once it is pasted on the other device, copy something else over it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: dim, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
