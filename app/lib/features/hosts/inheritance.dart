import 'models.dart';

/// What a host takes from its group when it leaves a field to it. A group
/// inside another group passes on its parent's defaults for whatever it
/// leaves blank itself.
///
/// The engine follows the same rules for connections it makes on its own
/// (SFTP sync), in `engine/crates/promptly-api/src/host_plan.rs`; keep the
/// two in step.
class Inherited {
  Inherited(this.host, List<Group> groups) : _groups = {for (final g in groups) g.id: g};

  final Host host;
  final Map<String, Group> _groups;

  /// The first value `key` has, from the host's group up through its
  /// parents, and the group that set it.
  ({T value, Group from})? _find<T>(String key, {String? startAt}) {
    final seen = <String>{};
    var id = startAt ?? host.groupId;
    while (id != null && seen.add(id)) {
      final g = _groups[id];
      if (g == null) break;
      final v = g.defaults[key];
      if (v is T && (v is! String || v.trim().isNotEmpty)) return (value: v, from: g);
      id = g.parentId;
    }
    return null;
  }

  /// The group's default user, which a blank User field takes.
  String? get groupUser => (_find<String>('username')?.value)?.trim();

  /// The group's default port, which a host left on 22 takes.
  int? get groupPort {
    final v = _find<num>('port')?.value.toInt();
    return v == null || v < 1 || v > 65535 ? null : v;
  }

  /// The group's default key, used by hosts set to Agent or Ask each time.
  String? get groupIdentityId => _find<String>('identity_id')?.value;

  /// The group's default jump host, for hosts that set none.
  String? get groupJumpHostId => _find<String>('jump_host_id')?.value;

  String get username => host.username.trim().isEmpty ? (groupUser ?? '') : host.username;

  int get port => host.port == 22 ? (groupPort ?? 22) : host.port;

  String? get jumpHostId => host.jumpHostId ?? groupJumpHostId;

  /// The login actually used: a host set to Agent or Ask each time uses
  /// the group's key when it has one. None stays None.
  HostAuth get auth {
    final key = groupIdentityId;
    if ((host.auth.kind == AuthKind.interactive || host.auth.kind == AuthKind.agent) && key != null) {
      return HostAuth(kind: AuthKind.identity, identityId: key);
    }
    return host.auth;
  }

  /// `user@hostname:port` with the inherited values.
  String get endpoint => '$username@${host.hostname}${port == 22 ? '' : ':$port'}';
}

/// Whether a search box query (already lower-cased) finds this host: its
/// label, address, user, tags or notes.
bool hostMatches(Host h, String query) {
  if (query.isEmpty) return true;
  return h.label.toLowerCase().contains(query) ||
      h.hostname.toLowerCase().contains(query) ||
      h.username.toLowerCase().contains(query) ||
      h.tags.any((t) => t.toLowerCase().contains(query)) ||
      h.notes.toLowerCase().contains(query);
}

/// "web, eu-west , db" as tags: trimmed, without blanks or repeats.
List<String> parseTags(String text) {
  final out = <String>[];
  for (final part in text.split(',')) {
    final t = part.trim();
    if (t.isNotEmpty && !out.any((o) => o.toLowerCase() == t.toLowerCase())) out.add(t);
  }
  return out;
}

/// Whether reaching [host] uses a saved private key anywhere: on the host
/// itself or on any jump host on the way, each with its group's defaults.
bool reachingUsesKey(Host host, List<Host> hosts, List<Group> groups) {
  final byId = {for (final h in hosts) h.id: h};
  final seen = <String>{};
  Host? h = host;
  while (h != null && seen.add(h.id)) {
    final inherited = Inherited(h, groups);
    if (inherited.auth.kind == AuthKind.identity) return true;
    final next = inherited.jumpHostId;
    h = next == null ? null : byId[next];
  }
  return false;
}
