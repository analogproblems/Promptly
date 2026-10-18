import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../hosts/repositories.dart';
import '../snippets/repositories.dart';
import '../settings/settings_providers.dart';

/// The vault's status: the last known value first, then every change the
/// engine reports (after each sync run, and whenever the setup changes).
final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final engine = ref.watch(engineProvider);
  try {
    yield engine.syncStatus();
  } catch (_) {
    // The stream below carries the first real status.
  }
  yield* engine.syncEvents();
});

/// A recovery code that still has to be shown and acknowledged. It outlives
/// the wizard, because creating the vault flips the status to configured
/// before the person has had a chance to write the code down.
final pendingRecoveryProvider = NotifierProvider<PendingRecovery, SyncSetupResult?>(PendingRecovery.new);

class PendingRecovery extends Notifier<SyncSetupResult?> {
  @override
  SyncSetupResult? build() => null;

  void set(SyncSetupResult? result) => state = result;
}

/// Reloads the saved hosts, groups, keys and synced settings whenever other
/// devices' changes land, so nothing shown is stale, and asks for a sync
/// whenever the app comes back to the front.
class SyncRefresh extends ConsumerStatefulWidget {
  const SyncRefresh({super.key, required this.child});

  final Widget child;

  /// A desktop window comes to the front every time it gets the focus
  /// back; one sync for a burst of those is plenty.
  static const resumeGap = Duration(seconds: 20);

  @override
  ConsumerState<SyncRefresh> createState() => _SyncRefreshState();
}

class _SyncRefreshState extends ConsumerState<SyncRefresh> {
  late final AppLifecycleListener _lifecycle;
  DateTime? _lastWake;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _resumed);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _resumed() {
    final status = ref.read(syncStatusProvider).value;
    if (status == null || !status.configured) return;
    final now = DateTime.now();
    if (_lastWake != null && now.difference(_lastWake!) < SyncRefresh.resumeGap) return;
    _lastWake = now;
    try {
      ref.read(engineProvider).syncWake();
    } catch (_) {
      // The status line reports sync trouble; coming to the front is no time for a dialog.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(syncStatusProvider, (previous, next) {
      final before = previous?.value?.changes;
      final after = next.value?.changes;
      if (after != null && before != null && after != before) {
        ref.invalidate(hostsProvider);
        ref.invalidate(groupsProvider);
        ref.invalidate(identitiesProvider);
        ref.invalidate(snippetsProvider);
        reloadSyncedSettings(ref);
      }
    });
    return widget.child;
  }
}

/// Pull a list down to sync now, once a vault is set up. The arc shows
/// while it runs and the list stays usable; a failure shows on the status
/// line, so there is nothing more to say here.
class PullToSync extends ConsumerWidget {
  const PullToSync({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!enabled) return child;
    return RefreshIndicator(
      key: const Key('pull-to-sync'),
      onRefresh: () async {
        try {
          await ref.read(engineProvider).syncNow();
        } catch (_) {}
      },
      child: child,
    );
  }
}

/// "Synced just now", "Syncing…", "Not set up", or the error.
String syncSummary(SyncStatus? s) {
  if (s == null) return 'Checking…';
  if (!s.configured) return 'Vault not set up';
  if (s.syncing) return 'Syncing…';
  if (s.attention case final a?) {
    return switch (a) {
      SyncAttention.updateNeeded => 'Sync paused: update Promptly',
      SyncAttention.passphraseChanged => 'Sync paused: type the new passphrase',
      SyncAttention.vaultMissing => 'Sync paused: the vault folder is missing',
      SyncAttention.differentVault => 'Sync paused: a different vault is in the folder',
      SyncAttention.removed => 'Sync stopped: this device was removed',
    };
  }
  if (s.lastError != null) return 'Sync problem: ${s.lastError}';
  final at = s.lastSyncAt == null ? null : DateTime.tryParse(s.lastSyncAt!);
  final when = at == null ? 'not yet' : relativeTimeOf(at);
  final n = s.devices.length;
  return 'Synced $when · $n ${n == 1 ? 'device' : 'devices'}';
}

/// "just now", "5 min ago", "2 h ago", "3 days ago".
String relativeTimeOf(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  return '${d.inDays} days ago';
}
