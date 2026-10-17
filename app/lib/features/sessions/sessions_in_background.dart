import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import 'session_manager.dart';

/// Looks after open sessions while the app is in the background. On a
/// phone or tablet, sessions whose connection dropped meanwhile reconnect
/// when it comes back. On Android a foreground service, with a
/// notification saying how many sessions are open, keeps them running in
/// the background from the first open session until the last one ends.
class SessionsInBackground extends ConsumerStatefulWidget {
  const SessionsInBackground({super.key, required this.child});

  final Widget child;

  /// Where the Android side (MainActivity) listens. `keepAlive` takes the
  /// number of open sessions; 0 stops the service.
  static const channel = MethodChannel('dev.promptly/sessions');

  @override
  ConsumerState<SessionsInBackground> createState() => _SessionsInBackgroundState();
}

class _SessionsInBackgroundState extends ConsumerState<SessionsInBackground> {
  late final AppLifecycleListener _lifecycle;
  List<SessionEntry> _watched = const [];

  /// The count the service was last given.
  int _told = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _lifecycleChanged);
    if (isAndroid) {
      ref.listenManual(sessionManagerProvider, (_, next) => _watch(next), fireImmediately: true);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _watch(const []);
    super.dispose();
  }

  /// A desktop window going behind another is not a phone app being put
  /// away, so only phones and tablets reconnect on coming back.
  void _lifecycleChanged(AppLifecycleState state) {
    if (!isTouchPlatform) return;
    final sessions = ref.read(sessionManagerProvider.notifier);
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        sessions.appPaused();
      case AppLifecycleState.resumed:
        sessions.appResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Follow every entry, since a session ends or comes back without the
  /// list changing.
  void _watch(List<SessionEntry> entries) {
    for (final e in _watched) {
      e.removeListener(_count);
    }
    _watched = entries;
    for (final e in entries) {
      e.addListener(_count);
    }
    _count();
  }

  /// Connecting, live or reconnecting: worth keeping the app running for.
  static bool _open(SessionEntry e) => e.isConnecting || e.reconnecting || e.controller?.exited == false;

  void _count() {
    final open = _watched.where(_open).length;
    if (open == _told) return;
    _told = open;
    SessionsInBackground.channel.invokeMethod<void>('keepAlive', open).catchError((Object _) {
      // Without the service sessions still work, only not in the background.
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
