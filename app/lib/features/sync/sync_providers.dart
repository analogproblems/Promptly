import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../hosts/repositories.dart';

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

/// Reloads the saved hosts, groups and keys whenever other devices' changes
/// land, so the lists are never stale.
class SyncRefresh extends ConsumerWidget {
  const SyncRefresh({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(syncStatusProvider, (previous, next) {
      final before = previous?.value?.changes;
      final after = next.value?.changes;
      if (after != null && before != null && after != before) {
        ref.invalidate(hostsProvider);
        ref.invalidate(groupsProvider);
        ref.invalidate(identitiesProvider);
      }
    });
    return child;
  }
}

/// "Synced just now", "Syncing…", "Not set up", or the error.
String syncSummary(SyncStatus? s) {
  if (s == null) return 'Checking…';
  if (!s.configured) return 'Vault not set up';
  if (s.syncing) return 'Syncing…';
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
