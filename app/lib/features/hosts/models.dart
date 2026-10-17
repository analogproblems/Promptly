import 'package:uuid/uuid.dart';

/// Records as the vault stores them. Field names here are the wire names in
/// `engine/crates/promptly-vault/src/model.rs`; the engine rejects a record
/// it cannot read back, so keep them in step.

const _uuid = Uuid();
String newRecordId() => _uuid.v7();

enum AuthKind { identity, password, agent, interactive, none }

enum ForwardKind { local, remote, dynamic }

/// A port forward saved on a host. Local: this device listens and the
/// server connects on. Remote: the server listens and this device connects
/// on. Dynamic: a SOCKS proxy on this device.
class PortForward {
  const PortForward({
    required this.kind,
    this.bindHost = '',
    required this.bindPort,
    this.targetHost = '',
    this.targetPort = 0,
    this.auto = true,
  });

  final ForwardKind kind;
  final String bindHost;
  final int bindPort;
  final String targetHost;
  final int targetPort;

  /// Start when the host connects.
  final bool auto;

  /// "8080 → db:5432", "server 9000 → 127.0.0.1:3000", "SOCKS on 1080".
  String get describe => switch (kind) {
        ForwardKind.local => '$bindPort → $targetHost:$targetPort',
        ForwardKind.remote => 'server $bindPort → $targetHost:$targetPort',
        ForwardKind.dynamic => 'SOCKS on $bindPort',
      };

  PortForward copyWith({ForwardKind? kind, String? bindHost, int? bindPort, String? targetHost, int? targetPort, bool? auto}) =>
      PortForward(
        kind: kind ?? this.kind,
        bindHost: bindHost ?? this.bindHost,
        bindPort: bindPort ?? this.bindPort,
        targetHost: targetHost ?? this.targetHost,
        targetPort: targetPort ?? this.targetPort,
        auto: auto ?? this.auto,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'bind_host': bindHost,
        'bind_port': bindPort,
        'target_host': targetHost,
        'target_port': targetPort,
        'auto': auto,
      };

  factory PortForward.fromJson(Map<String, dynamic> j) => PortForward(
        kind: ForwardKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => ForwardKind.local),
        bindHost: j['bind_host'] as String? ?? '',
        bindPort: (j['bind_port'] as num?)?.toInt() ?? 0,
        targetHost: j['target_host'] as String? ?? '',
        targetPort: (j['target_port'] as num?)?.toInt() ?? 0,
        auto: j['auto'] as bool? ?? false,
      );
}

class HostAuth {
  const HostAuth({required this.kind, this.identityId, this.passwordSecretId});

  final AuthKind kind;
  final String? identityId;
  final String? passwordSecretId;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (identityId != null) 'identity_id': identityId,
        if (passwordSecretId != null) 'password_secret_id': passwordSecretId,
      };

  factory HostAuth.fromJson(Map<String, dynamic> j) => HostAuth(
        kind: AuthKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => AuthKind.interactive),
        identityId: j['identity_id'] as String?,
        passwordSecretId: j['password_secret_id'] as String?,
      );
}

class Host {
  Host({
    required this.id,
    required this.label,
    required this.hostname,
    this.port = 22,
    this.username = '',
    this.auth = const HostAuth(kind: AuthKind.interactive),
    this.groupId,
    this.tags = const [],
    this.color,
    this.icon,
    this.notes = '',
    this.jumpHostId,
    this.keepaliveSeconds = 30,
    this.startupCommand,
    this.env = const {},
    this.persistentSession = false,
    this.agentForwarding = false,
    this.portForwards = const [],
    this.lastConnectedAt,
    this.favourite = false,
    this.production = false,
    this.productionLabel = '',
    this.sync = 'vault',
  });

  factory Host.create() => Host(id: newRecordId(), label: '', hostname: '');

  final String id;
  final String label;
  final String hostname;
  final int port;
  final String username;
  final HostAuth auth;
  final String? groupId;
  final List<String> tags;
  final String? color;
  final String? icon;
  final String notes;
  final String? jumpHostId;
  final int keepaliveSeconds;
  final String? startupCommand;
  final Map<String, String> env;
  final bool persistentSession;
  final bool agentForwarding;
  final List<PortForward> portForwards;
  final DateTime? lastConnectedAt;
  final bool favourite;

  /// Sessions to this host carry a red bar with [productionBadge].
  final bool production;

  /// The bar's words; blank means "Production".
  final String productionLabel;
  final String sync;

  /// What a production host's sessions say on their red bar.
  String get productionBadge => productionLabel.trim().isEmpty ? 'Production' : productionLabel.trim();

  String get endpoint => '$username@$hostname${port == 22 ? '' : ':$port'}';

  Host copyWith({
    String? label,
    String? hostname,
    int? port,
    String? username,
    HostAuth? auth,
    Object? groupId = _unset,
    List<String>? tags,
    Object? color = _unset,
    String? notes,
    int? keepaliveSeconds,
    Object? lastConnectedAt = _unset,
    bool? favourite,
    bool? production,
    String? productionLabel,
    Object? jumpHostId = _unset,
    Object? startupCommand = _unset,
    Map<String, String>? env,
    bool? persistentSession,
    bool? agentForwarding,
    List<PortForward>? portForwards,
    String? sync,
  }) =>
      Host(
        id: id,
        label: label ?? this.label,
        hostname: hostname ?? this.hostname,
        port: port ?? this.port,
        username: username ?? this.username,
        auth: auth ?? this.auth,
        groupId: groupId == _unset ? this.groupId : groupId as String?,
        tags: tags ?? this.tags,
        color: color == _unset ? this.color : color as String?,
        icon: icon,
        notes: notes ?? this.notes,
        jumpHostId: jumpHostId == _unset ? this.jumpHostId : jumpHostId as String?,
        keepaliveSeconds: keepaliveSeconds ?? this.keepaliveSeconds,
        startupCommand: startupCommand == _unset ? this.startupCommand : startupCommand as String?,
        env: env ?? this.env,
        persistentSession: persistentSession ?? this.persistentSession,
        agentForwarding: agentForwarding ?? this.agentForwarding,
        portForwards: portForwards ?? this.portForwards,
        lastConnectedAt: lastConnectedAt == _unset ? this.lastConnectedAt : lastConnectedAt as DateTime?,
        favourite: favourite ?? this.favourite,
        sync: sync ?? this.sync,
        production: production ?? this.production,
        productionLabel: productionLabel ?? this.productionLabel,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'hostname': hostname,
        'port': port,
        'username': username,
        'auth': auth.toJson(),
        'group_id': groupId,
        'tags': tags,
        'color': color,
        'icon': icon,
        'notes': notes,
        'jump_host_id': jumpHostId,
        'keepalive_seconds': keepaliveSeconds,
        'startup_command': startupCommand,
        'env': env,
        'persistent_session': persistentSession,
        'agent_forwarding': agentForwarding,
        'port_forwards': [for (final f in portForwards) f.toJson()],
        'last_connected_at': lastConnectedAt?.toUtc().toIso8601String(),
        'favourite': favourite,
        'production': production,
        'production_label': productionLabel,
        'sync': sync,
      };

  factory Host.fromJson(Map<String, dynamic> j) => Host(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        hostname: j['hostname'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        username: j['username'] as String? ?? '',
        auth: j['auth'] is Map ? HostAuth.fromJson((j['auth'] as Map).cast<String, dynamic>()) : const HostAuth(kind: AuthKind.interactive),
        groupId: j['group_id'] as String?,
        tags: (j['tags'] as List?)?.cast<String>() ?? const [],
        color: j['color'] as String?,
        icon: j['icon'] as String?,
        notes: j['notes'] as String? ?? '',
        jumpHostId: j['jump_host_id'] as String?,
        keepaliveSeconds: (j['keepalive_seconds'] as num?)?.toInt() ?? 30,
        startupCommand: j['startup_command'] as String?,
        env: (j['env'] as Map?)?.cast<String, String>() ?? const {},
        persistentSession: j['persistent_session'] as bool? ?? false,
        agentForwarding: j['agent_forwarding'] as bool? ?? false,
        portForwards: [
          for (final f in (j['port_forwards'] as List?) ?? const [])
            if (f is Map) PortForward.fromJson(f.cast<String, dynamic>()),
        ],
        lastConnectedAt: j['last_connected_at'] == null ? null : DateTime.tryParse(j['last_connected_at'] as String),
        favourite: j['favourite'] as bool? ?? false,
        production: j['production'] as bool? ?? false,
        productionLabel: j['production_label'] as String? ?? '',
        sync: j['sync'] as String? ?? 'vault',
      );
}

const _unset = Object();

class Group {
  Group({required this.id, required this.label, this.parentId, this.color, this.defaults = const {}});

  factory Group.create(String label) => Group(id: newRecordId(), label: label);

  final String id;
  final String label;
  final String? parentId;
  final String? color;
  final Map<String, dynamic> defaults;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'parent_id': parentId,
        'color': color,
        'defaults': defaults,
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        parentId: j['parent_id'] as String?,
        color: j['color'] as String?,
        defaults: (j['defaults'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

class Identity {
  Identity({
    required this.id,
    required this.label,
    required this.keyType,
    required this.publicKey,
    this.privateKeySecretId,
    this.passphraseSecretId,
    this.sync = 'vault',
  });

  final String id;
  final String label;

  /// `ed25519`, `ecdsa` or `rsa`.
  final String keyType;
  final String publicKey;
  final String? privateKeySecretId;
  final String? passphraseSecretId;
  final String sync;

  /// Kept on this device only: never synced, and gone from the vault.
  bool get localOnly => sync == 'local_only';

  Identity copyWith({String? sync}) => Identity(
        id: id,
        label: label,
        keyType: keyType,
        publicKey: publicKey,
        privateKeySecretId: privateKeySecretId,
        passphraseSecretId: passphraseSecretId,
        sync: sync ?? this.sync,
      );

  /// The same key with its saved passphrase at [secretId], or none.
  Identity withPassphraseSecret(String? secretId) => Identity(
        id: id,
        label: label,
        keyType: keyType,
        publicKey: publicKey,
        privateKeySecretId: privateKeySecretId,
        passphraseSecretId: secretId,
        sync: sync,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'key_type': keyType,
        'public_key': publicKey,
        'private_key_secret_id': privateKeySecretId,
        'hardware': null,
        'passphrase_secret_id': passphraseSecretId,
        'sync': sync,
      };

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        keyType: j['key_type'] as String? ?? 'ed25519',
        publicKey: j['public_key'] as String? ?? '',
        privateKeySecretId: j['private_key_secret_id'] as String?,
        passphraseSecretId: j['passphrase_secret_id'] as String?,
        sync: j['sync'] as String? ?? 'vault',
      );
}

/// The named colours a host or group can carry. Stored by name so themes
/// decide the exact shade.
const hostColorNames = ['red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'grey'];

/// A stable colour name for a host that has none set, from its label.
String defaultColorFor(String label) {
  var h = 0;
  for (final c in label.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return hostColorNames[h % hostColorNames.length];
}

/// "just now", "5m", "3h", "2d": how long ago something happened.
String relativeTime(DateTime? when, {DateTime? now}) {
  if (when == null) return '';
  final d = (now ?? DateTime.now()).difference(when);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 30) return '${d.inDays}d';
  return '${(d.inDays / 30).floor()}mo';
}
