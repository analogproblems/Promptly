import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../settings/settings_providers.dart';
import 'repositories.dart';

/// What the last knock on a host's port found.
class HostReach {
  const HostReach({required this.up, required this.millis, required this.at});

  final bool up;
  final int millis;
  final DateTime at;
}

/// The reachability of every saved host, refreshed once a minute while the
/// setting is on. Empty while it is off.
class HostReachabilityNotifier extends Notifier<Map<String, HostReach>> {
  Timer? _timer;
  bool _checking = false;

  static const period = Duration(minutes: 1);
  static const timeoutMs = 2000;

  @override
  Map<String, HostReach> build() {
    final on = ref.watch(reachabilityProvider);
    ref.watch(hostsProvider);
    _timer?.cancel();
    _timer = null;
    if (!on) return const {};
    _timer = Timer.periodic(period, (_) => refresh());
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(refresh);
    return stateOrNull ?? const {};
  }

  /// Knock now. Hosts that vanished drop out; the rest keep their last
  /// answer until the new one lands.
  Future<void> refresh() async {
    if (_checking || !ref.read(reachabilityProvider)) return;
    final hosts = ref.read(hostsProvider);
    if (hosts.isEmpty) {
      state = const {};
      return;
    }
    _checking = true;
    try {
      final results = await ref.read(engineProvider).hostsReachability(
            [for (final h in hosts) ReachTarget(id: h.id, host: h.hostname, port: h.port)],
            timeoutMs,
          );
      final now = DateTime.now();
      state = {
        for (final r in results) r.id: HostReach(up: r.reachable, millis: r.millis, at: now),
      };
    } catch (_) {
      // The next tick tries again.
    } finally {
      _checking = false;
    }
  }
}

final hostReachabilityProvider =
    NotifierProvider<HostReachabilityNotifier, Map<String, HostReach>>(HostReachabilityNotifier.new);
