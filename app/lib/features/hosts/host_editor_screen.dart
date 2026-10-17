import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../lock/app_lock.dart';
import '../sessions/connect_flow.dart';
import '../sessions/connecting_view.dart';
import '../sessions/session_manager.dart';
import '../settings/settings_providers.dart';
import 'host_colors.dart';
import 'inheritance.dart';
import 'models.dart';
import 'repositories.dart';

enum _AuthChoice { password, key, agent, ask, none }

const _authLabels = {
  _AuthChoice.password: 'Password',
  _AuthChoice.key: 'Key',
  _AuthChoice.agent: 'Agent',
  _AuthChoice.ask: 'Ask each time',
  _AuthChoice.none: 'None',
};

/// Add or edit a host. Saves to the engine's store; passwords go to the
/// secret store under an id the host record points at.
class HostEditorScreen extends ConsumerStatefulWidget {
  const HostEditorScreen({super.key, this.hostId});

  final String? hostId;

  @override
  ConsumerState<HostEditorScreen> createState() => _HostEditorScreenState();
}

class _HostEditorScreenState extends ConsumerState<HostEditorScreen> {
  final _form = GlobalKey<FormState>();
  late final Host _original;
  late final TextEditingController _label;
  late final TextEditingController _hostname;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _notes;
  late final TextEditingController _tags;
  late final TextEditingController _productionLabel;
  late final TextEditingController _keepalive;
  late final TextEditingController _startup;
  late final TextEditingController _env;
  late _AuthChoice _auth;
  String? _jumpHostId;
  late bool _persistent;
  late bool _agentForwarding;
  late List<PortForward> _forwards;

  /// One key per forward row that stays with it when rows above are removed,
  /// so each row keeps its own text fields.
  late List<int> _forwardKeys;
  int _nextForwardKey = 0;
  late bool _rememberPassword;
  String? _identityId;
  String? _groupId;
  String? _color;
  late bool _favourite;
  late bool _production;
  String? _error;

  bool get _isNew => widget.hostId == null;

  @override
  void initState() {
    super.initState();
    _original = (widget.hostId == null ? null : ref.read(hostsProvider.notifier).byId(widget.hostId!)) ?? Host.create();
    _label = TextEditingController(text: _original.label);
    _hostname = TextEditingController(text: _original.hostname);
    _port = TextEditingController(text: '${_original.port}');
    _username = TextEditingController(text: _original.username);
    _password = TextEditingController();
    _notes = TextEditingController(text: _original.notes);
    _tags = TextEditingController(text: _original.tags.join(', '));
    _productionLabel = TextEditingController(text: _original.productionLabel);
    _production = _original.production;
    _keepalive = TextEditingController(text: '${_original.keepaliveSeconds}');
    _startup = TextEditingController(text: _original.startupCommand ?? '');
    _env = TextEditingController(text: [for (final e in _original.env.entries) '${e.key}=${e.value}'].join('\n'));
    _jumpHostId = _original.jumpHostId;
    _persistent = _original.persistentSession;
    _agentForwarding = _original.agentForwarding;
    _forwards = [..._original.portForwards];
    _forwardKeys = [for (final _ in _forwards) _nextForwardKey++];
    _auth = switch (_original.auth.kind) {
      AuthKind.identity => _AuthChoice.key,
      AuthKind.password => _AuthChoice.password,
      AuthKind.agent => _AuthChoice.agent,
      AuthKind.none => _AuthChoice.none,
      _ => _AuthChoice.ask,
    };
    _rememberPassword = _original.auth.passwordSecretId != null;
    _identityId = _original.auth.identityId;
    _groupId = _original.groupId;
    _color = _original.color;
    _favourite = _original.favourite;
  }

  @override
  void dispose() {
    for (final c in [
      _label,
      _hostname,
      _port,
      _username,
      _password,
      _notes,
      _tags,
      _productionLabel,
      _keepalive,
      _startup,
      _env,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// What the selected group passes on to this host.
  Inherited get _inherited => Inherited(_original.copyWith(groupId: _groupId), ref.read(groupsProvider));

  /// The selected group's default user, which a blank User field takes.
  String? get _groupUser => _inherited.groupUser;

  /// The port typed in; blank (allowed when the group sets one) is 22,
  /// which takes the group's.
  int get _portValue => int.tryParse(_port.text.trim()) ?? 22;

  /// The host as the form now describes it, for saving or testing. Nothing
  /// is written.
  Host _formHost(HostAuth auth) => _original.copyWith(
    label: _label.text.trim().isEmpty ? _hostname.text.trim() : _label.text.trim(),
    hostname: _hostname.text.trim(),
    port: _portValue,
    username: _username.text.trim(),
    auth: auth,
    groupId: _groupId,
    tags: parseTags(_tags.text),
    color: _color,
    notes: _notes.text,
    keepaliveSeconds: int.tryParse(_keepalive.text.trim()) ?? 30,
    favourite: _favourite,
    production: _production,
    productionLabel: _productionLabel.text.trim(),
    jumpHostId: _jumpHostId,
    persistentSession: _persistent,
    agentForwarding: _agentForwarding,
    startupCommand: _startup.text.trim().isEmpty ? null : _startup.text.trim(),
    env: _parseEnv(_env.text),
    portForwards: [for (final f in _forwards) if (f.bindPort > 0) f],
  );

  /// Connect with what the form says, without saving: the real steps, any
  /// questions, then hang up.
  Future<void> _test() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final HostAuth auth;
    switch (_auth) {
      case _AuthChoice.key:
        if (_identityId == null) {
          setState(() => _error = 'Pick a key, or generate one on the Keys tab.');
          return;
        }
        auth = HostAuth(kind: AuthKind.identity, identityId: _identityId);
      case _AuthChoice.password:
        // A saved password is used unless a new one is typed.
        auth = HostAuth(
          kind: AuthKind.password,
          passwordSecretId: _password.text.isEmpty && _rememberPassword ? _original.auth.passwordSecretId : null,
        );
      case _AuthChoice.agent:
        auth = const HostAuth(kind: AuthKind.agent);
      case _AuthChoice.ask:
        auth = const HostAuth(kind: AuthKind.interactive);
      case _AuthChoice.none:
        auth = const HostAuth(kind: AuthKind.none);
    }
    setState(() => _error = null);
    final plan = ref
        .read(sessionManagerProvider.notifier)
        .requestFor(_formHost(auth), theme: terminalThemeFor(ref, context));
    final r = plan.request;
    if (r == null) {
      setState(() => _error = plan.problem);
      return;
    }
    final typed = _auth == _AuthChoice.password && _password.text.isNotEmpty ? _password.text : null;
    // Only the login is tested: no startup command, tmux or forwards.
    final request = SshConnectRequest(
      user: r.user,
      host: r.host,
      port: r.port,
      auth: r.auth,
      password: typed ?? r.password,
      privateKey: r.privateKey,
      passphrase: r.passphrase,
      cols: r.cols,
      rows: r.rows,
      theme: r.theme,
      label: r.label,
      keepaliveSeconds: r.keepaliveSeconds,
      reattachSessionId: null,
      jumps: r.jumps,
      persistent: false,
      startupCommand: null,
      env: const [],
      agentForward: false,
      forwards: const [],
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TestConnectionDialog(engine: ref.read(engineProvider), request: request),
    );
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final engine = ref.read(engineProvider);

    HostAuth auth;
    // A password that is no longer remembered, forgotten once the host saves.
    String? retiredSecretId;
    switch (_auth) {
      case _AuthChoice.key:
        if (_identityId == null) {
          setState(() => _error = 'Pick a key, or generate one on the Keys tab.');
          return;
        }
        auth = HostAuth(kind: AuthKind.identity, identityId: _identityId);
      case _AuthChoice.password:
        final secretId = _original.auth.passwordSecretId ?? newRecordId();
        if (_rememberPassword && _password.text.isNotEmpty) {
          try {
            engine.secretPut(secretId, 'password', _password.text);
          } catch (e) {
            setState(() => _error = 'Could not save the password: $e');
            return;
          }
          auth = HostAuth(kind: AuthKind.password, passwordSecretId: secretId);
        } else if (_rememberPassword && _original.auth.passwordSecretId != null) {
          auth = HostAuth(kind: AuthKind.password, passwordSecretId: secretId);
        } else {
          retiredSecretId = _original.auth.passwordSecretId;
          auth = const HostAuth(kind: AuthKind.password);
        }
      case _AuthChoice.agent:
        auth = const HostAuth(kind: AuthKind.agent);
      case _AuthChoice.ask:
        auth = const HostAuth(kind: AuthKind.interactive);
      case _AuthChoice.none:
        auth = const HostAuth(kind: AuthKind.none);
    }

    final host = _formHost(auth);
    try {
      ref.read(hostsProvider.notifier).save(host);
    } catch (e) {
      setState(() => _error = e is String ? e : e.toString());
      return;
    }
    if (retiredSecretId != null) {
      try {
        engine.secretDelete(retiredSecretId);
      } catch (_) {}
    }
    context.go('/hosts');
  }

  /// "NAME=value" lines; blank lines and lines without "=" are skipped.
  static Map<String, String> _parseEnv(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final name = line.substring(0, eq).trim();
      if (name.isEmpty) continue;
      out[name] = line.substring(eq + 1).trim();
    }
    return out;
  }

  Future<void> _newGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Production, Homelab, Clients…'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    final group = ref.read(groupsProvider.notifier).save(Group.create(trimmed));
    setState(() => _groupId = group.id);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${_original.label}?'),
        content: const Text('The host and its saved password are removed. Keys are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.tokens.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      ref.read(hostsProvider.notifier).delete(_original.id);
      context.go('/hosts');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final identities = ref.watch(identitiesProvider);
    final groups = ref.watch(groupsProvider);
    final otherHosts = [for (final h in ref.watch(hostsProvider)) if (h.id != _original.id) h];
    final brightness = Theme.of(context).brightness;
    ref.watch(groupsProvider);
    final inherited = _inherited;
    final groupPort = inherited.groupPort;
    final groupKey = ref.read(identitiesProvider.notifier).byId(inherited.groupIdentityId);
    final groupJump = ref.read(hostsProvider.notifier).byId(inherited.groupJumpHostId ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 56,
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: () => context.go('/hosts'),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _isNew ? 'New host' : 'Edit host',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: t.text),
                ),
              ),
              FilledButton(key: const Key('host-save'), onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
        Expanded(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                _Section(
                  title: 'Basics',
                  children: [
                    TextFormField(
                      key: const Key('host-label'),
                      controller: _label,
                      style: monoStyle(context, size: 14),
                      decoration: const InputDecoration(labelText: 'Label', hintText: 'web-1'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextFormField(
                            key: const Key('host-hostname'),
                            controller: _hostname,
                            style: monoStyle(context, size: 14),
                            decoration: const InputDecoration(labelText: 'Hostname or IP'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Needed' : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 96,
                          child: TextFormField(
                            key: const Key('host-port'),
                            controller: _port,
                            style: monoStyle(context, size: 14),
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(labelText: 'Port', hintText: groupPort?.toString()),
                            validator: (v) {
                              if ((v ?? '').trim().isEmpty && groupPort != null) return null;
                              final n = int.tryParse(v?.trim() ?? '');
                              return (n == null || n < 1 || n > 65535) ? '1 to 65535' : null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      key: const Key('host-username'),
                      controller: _username,
                      style: monoStyle(context, size: 14),
                      decoration: InputDecoration(
                        labelText: 'User',
                        helperText: _groupUser == null ? null : 'Blank uses the group\'s $_groupUser',
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) && _groupUser == null ? 'Needed' : null,
                    ),
                    if (groupPort != null && groupPort != 22 && _portValue == 22) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Port 22 or blank uses the group\'s port, $groupPort.',
                        key: const Key('host-port-inherited'),
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Authentication',
                  children: [
                    // Five choices don't fit side by side on a phone without
                    // breaking words, so narrow screens get a dropdown.
                    LayoutBuilder(
                      builder: (context, constraints) => constraints.maxWidth < 520
                          ? DropdownButtonFormField<_AuthChoice>(
                              initialValue: _auth,
                              isExpanded: true,
                              decoration: const InputDecoration(labelText: 'Sign in with'),
                              items: [
                                for (final c in _AuthChoice.values)
                                  DropdownMenuItem(value: c, child: Text(_authLabels[c]!)),
                              ],
                              onChanged: (c) => setState(() => _auth = c ?? _auth),
                            )
                          : SegmentedButton<_AuthChoice>(
                              showSelectedIcon: false,
                              segments: [
                                for (final c in _AuthChoice.values)
                                  ButtonSegment(value: c, label: Text(_authLabels[c]!)),
                              ],
                              selected: {_auth},
                              onSelectionChanged: (s) => setState(() => _auth = s.first),
                            ),
                    ),
                    const SizedBox(height: 12),
                    if (_auth == _AuthChoice.password) ...[
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        style: monoStyle(context, size: 14),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          hintText: _original.auth.passwordSecretId != null && _rememberPassword
                              ? 'A password is saved. Type to replace it.'
                              : 'Leave empty to be asked each time',
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Remember the password on this device'),
                        value: _rememberPassword,
                        onChanged: (v) => setState(() => _rememberPassword = v),
                      ),
                    ],
                    if (_auth == _AuthChoice.key)
                      identities.isEmpty
                          ? Text(
                              'No keys yet. Generate one on the Keys tab, then come back.',
                              style: TextStyle(color: t.muted, fontSize: 13),
                            )
                          : DropdownButtonFormField<String>(
                              initialValue: identities.any((i) => i.id == _identityId) ? _identityId : null,
                              isExpanded: true,
                              decoration: const InputDecoration(labelText: 'Key'),
                              items: [
                                for (final i in identities)
                                  DropdownMenuItem(
                                    value: i.id,
                                    child: Text('${i.label} (${i.keyType})', overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (v) => setState(() => _identityId = v),
                            ),
                    if ((_auth == _AuthChoice.agent || _auth == _AuthChoice.ask) && groupKey != null) ...[
                      Text(
                        'Uses the group\'s key, ${groupKey.label}.',
                        key: const Key('host-key-inherited'),
                        style: TextStyle(color: t.text, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (_auth == _AuthChoice.ask)
                      Text(
                        'The server decides: a password prompt, a two-factor code, or both. '
                        'If it needs nothing, you go straight in.',
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                    if (_auth == _AuthChoice.none)
                      Text(
                        'For servers that check who you are another way, like Tailscale SSH.',
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('host-test'),
                        onPressed: _test,
                        icon: const Icon(Icons.network_check),
                        label: const Text('Test connection'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Organise',
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String?>(
                            initialValue: groups.any((g) => g.id == _groupId) ? _groupId : null,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: 'Group'),
                            items: [
                              const DropdownMenuItem<String?>(value: null, child: Text('No group')),
                              for (final g in groups)
                                DropdownMenuItem(value: g.id, child: Text(g.label, overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => setState(() => _groupId = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: _newGroup, child: const Text('New group')),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text('Colour', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.muted)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final name in hostColorNames)
                          InkWell(
                            onTap: () => setState(() => _color = name),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: hostColor(name, brightness).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: (_color ?? defaultColorFor(_label.text)) == name
                                      ? hostColor(name, brightness)
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(color: hostColor(name, brightness), shape: BoxShape.circle),
                              ),
                            ),
                          ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Favourite'),
                      value: _favourite,
                      onChanged: (v) => setState(() => _favourite = v),
                    ),
                    const SizedBox(height: 4),
                    TextFormField(
                      key: const Key('host-tags'),
                      controller: _tags,
                      style: monoStyle(context, size: 14),
                      decoration: const InputDecoration(
                        labelText: 'Tags',
                        hintText: 'web, eu-west',
                        helperText: 'Separate tags with commas. Search finds hosts by tag.',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    if (parseTags(_tags.text).isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in parseTags(_tags.text))
                            Chip(label: Text(tag), visualDensity: VisualDensity.compact),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                    SwitchListTile(
                      key: const Key('host-production'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Mark as production'),
                      subtitle: const Text('Its sessions get a red bar with a label, so you always know.'),
                      value: _production,
                      onChanged: (v) => setState(() => _production = v),
                    ),
                    if (_production)
                      TextFormField(
                        key: const Key('host-production-label'),
                        controller: _productionLabel,
                        decoration: const InputDecoration(
                          labelText: 'Label on the bar',
                          hintText: 'Production',
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Connection',
                  children: [
                    DropdownButtonFormField<String?>(
                      key: const Key('host-jump'),
                      initialValue: otherHosts.any((h) => h.id == _jumpHostId) ? _jumpHostId : null,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Jump host',
                        helperText: 'Connect through this host first. It can have a jump host of its own.',
                        helperMaxLines: 3,
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(
                            groupJump == null || groupJump.id == _original.id
                                ? 'None, connect directly'
                                : 'The group\'s: ${groupJump.label}',
                            key: const Key('host-jump-inherited'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        for (final h in otherHosts)
                          DropdownMenuItem(value: h.id, child: Text(h.label, overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) => setState(() => _jumpHostId = v),
                    ),
                    SwitchListTile(
                      key: const Key('host-persistent'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Persistent session'),
                      subtitle: const Text(
                        'Attach to a tmux session on the server, so your work survives a dropped connection or a phone going to sleep.',
                      ),
                      value: _persistent,
                      onChanged: (v) => setState(() => _persistent = v),
                    ),
                    SwitchListTile(
                      key: const Key('host-agent-forwarding'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Agent forwarding'),
                      subtitle: const Text(
                        'Let programs on the server use the SSH agent on this device. Only for servers you trust.',
                      ),
                      value: _agentForwarding,
                      onChanged: (v) => setState(() => _agentForwarding = v),
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      key: const Key('host-startup'),
                      controller: _startup,
                      style: monoStyle(context, size: 14),
                      decoration: const InputDecoration(
                        labelText: 'Startup command',
                        hintText: 'cd /srv/app && git status',
                        helperText: 'Typed into the shell when the session opens.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      key: const Key('host-env'),
                      controller: _env,
                      maxLines: 3,
                      style: monoStyle(context, size: 14),
                      decoration: const InputDecoration(
                        labelText: 'Environment',
                        hintText: 'NAME=value, one per line',
                        helperText: 'Sent to the server, which only accepts the names its AcceptEnv lists.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _keepalive,
                      keyboardType: TextInputType.number,
                      style: monoStyle(context, size: 14),
                      decoration: const InputDecoration(
                        labelText: 'Keep-alive, seconds',
                        helperText: 'How often to ping the server so idle connections stay open. 0 turns it off.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Port forwards',
                  children: [
                    if (_forwards.isEmpty)
                      Text(
                        'Reach a database or web app behind the server from this device, expose a local port on the server, or run a SOCKS proxy through it.',
                        style: TextStyle(color: t.muted, fontSize: 13),
                      ),
                    for (var i = 0; i < _forwards.length; i++)
                      _ForwardEditor(
                        key: ValueKey('forward-row-${_forwardKeys[i]}'),
                        index: i,
                        forward: _forwards[i],
                        onChanged: (f) => setState(() => _forwards[i] = f),
                        onRemove: () => setState(() {
                          _forwards.removeAt(i);
                          _forwardKeys.removeAt(i);
                        }),
                      ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('forward-add'),
                        onPressed: () => setState(() {
                          _forwards.add(const PortForward(kind: ForwardKind.local, bindPort: 0, targetHost: 'localhost'));
                          _forwardKeys.add(_nextForwardKey++);
                        }),
                        icon: const Icon(Icons.add),
                        label: const Text('Add forward'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Notes',
                  children: [
                    TextFormField(
                      controller: _notes,
                      maxLines: 4,
                      decoration: const InputDecoration(hintText: 'Anything worth remembering about this box'),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: TextStyle(color: t.danger)),
                ],
                if (!_isNew) ...[
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(foregroundColor: t.danger),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete host'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One port forward's fields. Keeps its own text controllers; the parent
/// holds the value.
class _ForwardEditor extends StatefulWidget {
  const _ForwardEditor({
    super.key,
    required this.index,
    required this.forward,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final PortForward forward;
  final ValueChanged<PortForward> onChanged;
  final VoidCallback onRemove;

  @override
  State<_ForwardEditor> createState() => _ForwardEditorState();
}

class _ForwardEditorState extends State<_ForwardEditor> {
  late final TextEditingController _port;
  late final TextEditingController _targetHost;
  late final TextEditingController _targetPort;

  @override
  void initState() {
    super.initState();
    final f = widget.forward;
    _port = TextEditingController(text: f.bindPort == 0 ? '' : '${f.bindPort}');
    _targetHost = TextEditingController(text: f.targetHost);
    _targetPort = TextEditingController(text: f.targetPort == 0 ? '' : '${f.targetPort}');
  }

  @override
  void dispose() {
    _port.dispose();
    _targetHost.dispose();
    _targetPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final f = widget.forward;
    final i = widget.index;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<ForwardKind>(
                  key: Key('forward-kind-$i'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ForwardKind.local, label: Text('Local')),
                    ButtonSegment(value: ForwardKind.remote, label: Text('Remote')),
                    ButtonSegment(value: ForwardKind.dynamic, label: Text('SOCKS')),
                  ],
                  selected: {f.kind},
                  onSelectionChanged: (s) => widget.onChanged(f.copyWith(kind: s.first)),
                ),
              ),
              IconButton(
                key: Key('forward-remove-$i'),
                tooltip: 'Remove forward',
                onPressed: widget.onRemove,
                icon: Icon(Icons.delete_outline, color: t.muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: TextFormField(
                  key: Key('forward-port-$i'),
                  controller: _port,
                  keyboardType: TextInputType.number,
                  style: monoStyle(context, size: 14),
                  decoration: InputDecoration(labelText: f.kind == ForwardKind.remote ? 'Server port' : 'Port here'),
                  onChanged: (v) => widget.onChanged(f.copyWith(bindPort: int.tryParse(v.trim()) ?? 0)),
                ),
              ),
              if (f.kind != ForwardKind.dynamic) ...[
                const SizedBox(width: 10),
                Icon(Icons.arrow_forward, size: 16, color: t.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    key: Key('forward-target-host-$i'),
                    controller: _targetHost,
                    style: monoStyle(context, size: 14),
                    decoration: InputDecoration(
                      labelText: f.kind == ForwardKind.local ? 'Host, as the server sees it' : 'Host, as this device sees it',
                    ),
                    onChanged: (v) => widget.onChanged(f.copyWith(targetHost: v.trim())),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  child: TextFormField(
                    key: Key('forward-target-port-$i'),
                    controller: _targetPort,
                    keyboardType: TextInputType.number,
                    style: monoStyle(context, size: 14),
                    decoration: const InputDecoration(labelText: 'Port'),
                    onChanged: (v) => widget.onChanged(f.copyWith(targetPort: int.tryParse(v.trim()) ?? 0)),
                  ),
                ),
              ],
            ],
          ),
          SwitchListTile(
            key: Key('forward-auto-$i'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Start when the host connects'),
            value: f.auto,
            onChanged: (v) => widget.onChanged(f.copyWith(auto: v)),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
  }
}

/// "Test connection": the real connect flow, its steps and questions, in a
/// dialog. A login that works is hung up straight away.
class _TestConnectionDialog extends ConsumerStatefulWidget {
  const _TestConnectionDialog({required this.engine, required this.request});

  final Engine engine;
  final SshConnectRequest request;

  @override
  ConsumerState<_TestConnectionDialog> createState() => _TestConnectionDialogState();
}

class _TestConnectionDialogState extends ConsumerState<_TestConnectionDialog> {
  late ConnectFlow _flow;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _flow = ConnectFlow(
      engine: widget.engine,
      request: widget.request,
      unlock: () => ref.read(appLockProvider.notifier).unlockKeys(),
    )..addListener(_onFlow);
    _flow.start();
  }

  void _onFlow() {
    // It worked: nothing more to do with the session.
    if (_flow.sessionId != null) _flow.discard();
    setState(() {});
  }

  void _stop() {
    _flow
      ..removeListener(_onFlow)
      ..cancel()
      ..dispose();
  }

  void _again() {
    _stop();
    setState(_start);
  }

  void _close() => Navigator.pop(context);

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ok = _flow.sessionId != null;
    return AlertDialog(
      title: const Text('Test connection'),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(PromptlyTokens.controlRadius),
                child: ConnectingView(flow: _flow, onCancel: _close, onRetry: _again),
              ),
            ),
            if (ok)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: t.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Connection works. Promptly signed in and hung up again.',
                        key: const Key('host-test-ok'),
                        style: TextStyle(color: t.text),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(key: const Key('host-test-close'), onPressed: _close, child: const Text('Close')),
      ],
    );
  }
}
