import 'package:uuid/uuid.dart';

/// Records as the vault stores them. Field names here are the wire names in
/// `engine/crates/promptly-vault/src/model.rs`; the engine rejects a record
/// it cannot read back, so keep them in step.

const _uuid = Uuid();
String newRecordId() => _uuid.v7();

enum AuthKind { identity, password, agent, interactive }

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
    this.portForwards = const [],
    this.lastConnectedAt,
    this.favourite = false,
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
  final List<dynamic> portForwards;
  final DateTime? lastConnectedAt;
  final bool favourite;
  final String sync;

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
        jumpHostId: jumpHostId,
        keepaliveSeconds: keepaliveSeconds ?? this.keepaliveSeconds,
        startupCommand: startupCommand,
        env: env,
        persistentSession: persistentSession,
        portForwards: portForwards,
        lastConnectedAt: lastConnectedAt == _unset ? this.lastConnectedAt : lastConnectedAt as DateTime?,
        favourite: favourite ?? this.favourite,
        sync: sync,
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
        'port_forwards': portForwards,
        'last_connected_at': lastConnectedAt?.toUtc().toIso8601String(),
        'favourite': favourite,
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
        portForwards: (j['port_forwards'] as List?) ?? const [],
        lastConnectedAt: j['last_connected_at'] == null ? null : DateTime.tryParse(j['last_connected_at'] as String),
        favourite: j['favourite'] as bool? ?? false,
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
