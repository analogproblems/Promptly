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
  /// With [localOnly] the key never leaves this device.
  Identity generate({required String label, required SshKeyKind kind, bool localOnly = false}) {
    final engine = ref.read(engineProvider);
    final id = newRecordId();
    final generated = engine.keyGenerate(kind, label);
    // Secret ids are record ids too: the engine's model types them as UUIDs.
    final secretId = newRecordId();
    final identity = Identity(
      id: id,
      label: label,
      keyType: generated.kind,
      publicKey: generated.publicOpenssh,
      privateKeySecretId: secretId,
      sync: localOnly ? 'local_only' : 'vault',
    );
    _saveWithSecret(identity, secretId, generated.privateOpenssh);
    return identity;
  }

  /// The identity first, so it says whether its key may leave this device
  /// before the key is saved; then the key. A key that cannot be saved
  /// takes the identity with it.
  void _saveWithSecret(Identity identity, String secretId, String privateKey) {
    final engine = ref.read(engineProvider);
    engine.recordPut('identities', identity.id, jsonEncode(identity.toJson()));
    try {
      engine.secretPut(secretId, 'private_key', privateKey);
    } catch (_) {
      try {
        engine.recordDelete('identities', identity.id);
      } catch (_) {}
      state = _load();
      rethrow;
    }
    state = _load();
  }

  /// Keep a key on this device only, or let it sync again. Kept here, it
  /// leaves the vault and your other devices; nothing is deleted here.
  void setLocalOnly(String id, bool localOnly) {
    final identity = byId(id);
    if (identity == null) return;
    ref.read(engineProvider).recordPut(
          'identities',
          id,
          jsonEncode(identity.copyWith(sync: localOnly ? 'local_only' : 'vault').toJson()),
        );
    state = _load();
  }

  /// Import a pasted private key. Encrypted keys are kept encrypted; with
  /// [rememberPassphrase] the passphrase given is saved with the key,
  /// otherwise it is asked for at connect time. A PuTTY or PEM key that
  /// could be read in full is stored in OpenSSH form instead, behind the
  /// same passphrase if it had one.
  Identity import({
    required String label,
    required String privateKey,
    String? passphrase,
    bool localOnly = false,
    bool rememberPassphrase = false,
  }) {
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
    final identity = Identity(
      id: id,
      label: label,
      keyType: info.kind,
      publicKey: publicKey,
      privateKeySecretId: secretId,
      sync: localOnly ? 'local_only' : 'vault',
    );
    _saveWithSecret(identity, secretId, stored);
    if (rememberPassphrase && passphrase != null) {
      try {
        if (engine.keyInspect(stored, null).encrypted) savePassphrase(id, passphrase);
      } catch (_) {
        // The key is in; its passphrase is asked for when connecting.
      }
    }
    return byId(id) ?? identity;
  }

  /// Remember the passphrase that unlocks a key, as a secret like a saved
  /// password. It goes where the key goes: kept on this device with a key
  /// kept here, synced with one that syncs. The key's record names the
  /// secret first, so it says where the secret may go before it exists.
  void savePassphrase(String id, String passphrase) {
    final identity = byId(id);
    if (identity == null) return;
    final engine = ref.read(engineProvider);
    final existing = identity.passphraseSecretId;
    if (existing != null) {
      engine.secretPut(existing, 'key_passphrase', passphrase);
      return;
    }
    // Secret ids are record ids too: the engine's model types them as UUIDs.
    final secretId = newRecordId();
    engine.recordPut('identities', id, jsonEncode(identity.withPassphraseSecret(secretId).toJson()));
    try {
      engine.secretPut(secretId, 'key_passphrase', passphrase);
    } catch (_) {
      try {
        engine.recordPut('identities', id, jsonEncode(identity.toJson()));
      } catch (_) {}
      state = _load();
      rethrow;
    }
    state = _load();
  }

  /// The key's saved passphrase, if it has one and it can be read.
  String? passphraseFor(Identity? identity) {
    final secretId = identity?.passphraseSecretId;
    if (secretId == null) return null;
    try {
      return ref.read(engineProvider).secretGet(secretId);
    } catch (_) {
      return null;
    }
  }

  /// Forget a key's saved passphrase, here and, if it synced, everywhere.
  void forgetPassphrase(String id) {
    final identity = byId(id);
    final secretId = identity?.passphraseSecretId;
    if (identity == null || secretId == null) return;
    final engine = ref.read(engineProvider);
    try {
      engine.secretDelete(secretId);
    } catch (_) {}
    engine.recordPut('identities', id, jsonEncode(identity.withPassphraseSecret(null).toJson()));
    state = _load();
  }

  void delete(String id) {
    final engine = ref.read(engineProvider);
    final identity = byId(id);
    for (final secretId in [identity?.privateKeySecretId, identity?.passphraseSecretId]) {
      if (secretId == null) continue;
      try {
        engine.secretDelete(secretId);
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
