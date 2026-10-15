import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import 'models.dart';

/// Saved hosts, loaded from the engine's store. Mutations write through and
/// reload, so the list is always what the store holds.
class HostsNotifier extends Notifier<List<Host>> {
  @override
  List<Host> build() => _load();

  List<Host> _load() {
    try {
      final hosts = ref
          .read(engineProvider)
          .recordsList('hosts')
          .map((r) => Host.fromJson(jsonDecode(r.json) as Map<String, dynamic>))
          .toList();
      hosts.sort((a, b) {
        if (a.favourite != b.favourite) return a.favourite ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      return hosts;
    } catch (_) {
      return const [];
    }
  }

  void save(Host host) {
    ref.read(engineProvider).recordPut('hosts', host.id, jsonEncode(host.toJson()));
    state = _load();
  }

  void delete(String id) {
    final engine = ref.read(engineProvider);
    final host = byId(id);
    final secret = host?.auth.passwordSecretId;
    if (secret != null) {
      try {
        engine.secretDelete(secret);
      } catch (_) {}
    }
    engine.recordDelete('hosts', id);
    state = _load();
  }

  void markConnected(String id) {
    final host = byId(id);
    if (host != null) save(host.copyWith(lastConnectedAt: DateTime.now()));
  }

  void toggleFavourite(String id) {
    final host = byId(id);
    if (host != null) save(host.copyWith(favourite: !host.favourite));
  }

  Host? byId(String id) {
    for (final h in state) {
      if (h.id == id) return h;
    }
    return null;
  }
}

final hostsProvider = NotifierProvider<HostsNotifier, List<Host>>(HostsNotifier.new);

class GroupsNotifier extends Notifier<List<Group>> {
  @override
  List<Group> build() => _load();

  List<Group> _load() {
    try {
      final groups = ref
          .read(engineProvider)
          .recordsList('groups')
          .map((r) => Group.fromJson(jsonDecode(r.json) as Map<String, dynamic>))
          .toList();
      groups.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return groups;
    } catch (_) {
      return const [];
    }
  }

  Group save(Group group) {
    ref.read(engineProvider).recordPut('groups', group.id, jsonEncode(group.toJson()));
    state = _load();
    return group;
  }

  void delete(String id) {
    ref.read(engineProvider).recordDelete('groups', id);
    state = _load();
  }

  Group? byId(String? id) {
    if (id == null) return null;
    for (final g in state) {
      if (g.id == id) return g;
    }
    return null;
  }
}

final groupsProvider = NotifierProvider<GroupsNotifier, List<Group>>(GroupsNotifier.new);

class IdentitiesNotifier extends Notifier<List<Identity>> {
  @override
  List<Identity> build() => _load();

  List<Identity> _load() {
    try {
      final ids = ref
          .read(engineProvider)
          .recordsList('identities')
          .map((r) => Identity.fromJson(jsonDecode(r.json) as Map<String, dynamic>))
          .toList();
      ids.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return ids;
    } catch (_) {
      return const [];
    }
  }

  /// Generate a key pair in the engine and keep the private half in the
  /// secret store. Returns the new identity.
  Identity generate({required String label, required SshKeyKind kind}) {
    final engine = ref.read(engineProvider);
    final id = newRecordId();
    final generated = engine.keyGenerate(kind, label);
    // Secret ids are record ids too: the engine's model types them as UUIDs.
    final secretId = newRecordId();
    engine.secretPut(secretId, 'private_key', generated.privateOpenssh);
    final identity = Identity(
      id: id,
      label: label,
      keyType: generated.kind,
      publicKey: generated.publicOpenssh,
      privateKeySecretId: secretId,
    );
    engine.recordPut('identities', id, jsonEncode(identity.toJson()));
    state = _load();
    return identity;
  }

  /// Import a pasted private key. Encrypted keys are kept encrypted; the
  /// passphrase is asked for at connect time. A PuTTY or PEM key that
  /// could be read in full is stored in OpenSSH form instead.
  Identity import({required String label, required String privateKey, String? passphrase}) {
    final engine = ref.read(engineProvider);
    final info = engine.keyInspect(privateKey, passphrase);
    final publicKey = info.publicOpenssh;
    if (publicKey == null) {
      throw 'This key is encrypted. Enter its passphrase so the public half can be read.';
    }
    final id = newRecordId();
    // Secret ids are record ids too: the engine's model types them as UUIDs.
    final secretId = newRecordId();
    final stored = info.converted && info.privateOpenssh != null ? info.privateOpenssh! : privateKey.trim();
    engine.secretPut(secretId, 'private_key', stored);
    final identity = Identity(
      id: id,
      label: label,
      keyType: info.kind,
      publicKey: publicKey,
      privateKeySecretId: secretId,
    );
    engine.recordPut('identities', id, jsonEncode(identity.toJson()));
    state = _load();
    return identity;
  }

  void delete(String id) {
    final engine = ref.read(engineProvider);
    final identity = byId(id);
    if (identity?.privateKeySecretId != null) {
      try {
        engine.secretDelete(identity!.privateKeySecretId!);
      } catch (_) {}
    }
    engine.recordDelete('identities', id);
    state = _load();
  }

  Identity? byId(String? id) {
    if (id == null) return null;
    for (final i in state) {
      if (i.id == id) return i;
    }
    return null;
  }
}

final identitiesProvider = NotifierProvider<IdentitiesNotifier, List<Identity>>(IdentitiesNotifier.new);
