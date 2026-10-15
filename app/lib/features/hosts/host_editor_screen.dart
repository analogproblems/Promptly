import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import 'host_colors.dart';
import 'models.dart';
import 'repositories.dart';

enum _AuthChoice { password, key, agent, ask }

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
  late final TextEditingController _keepalive;
  late _AuthChoice _auth;
  late bool _rememberPassword;
  String? _identityId;
  String? _groupId;
  String? _color;
  late bool _favourite;
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
    _keepalive = TextEditingController(text: '${_original.keepaliveSeconds}');
    _auth = switch (_original.auth.kind) {
      AuthKind.identity => _AuthChoice.key,
      AuthKind.password => _AuthChoice.password,
      AuthKind.agent => _AuthChoice.agent,
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
    for (final c in [_label, _hostname, _port, _username, _password, _notes, _keepalive]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final engine = ref.read(engineProvider);
    final label = _label.text.trim().isEmpty ? _hostname.text.trim() : _label.text.trim();

    HostAuth auth;
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
          engine.secretPut(secretId, 'password', _password.text);
          auth = HostAuth(kind: AuthKind.password, passwordSecretId: secretId);
        } else if (_rememberPassword && _original.auth.passwordSecretId != null) {
          auth = HostAuth(kind: AuthKind.password, passwordSecretId: secretId);
        } else {
          if (_original.auth.passwordSecretId != null) {
            try {
              engine.secretDelete(secretId);
            } catch (_) {}
          }
          auth = const HostAuth(kind: AuthKind.password);
        }
      case _AuthChoice.agent:
        auth = const HostAuth(kind: AuthKind.agent);
      case _AuthChoice.ask:
        auth = const HostAuth(kind: AuthKind.interactive);
    }

    final host = _original.copyWith(
      label: label,
      hostname: _hostname.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _username.text.trim(),
      auth: auth,
      groupId: _groupId,
      color: _color,
      notes: _notes.text,
      keepaliveSeconds: int.tryParse(_keepalive.text.trim()) ?? 30,
      favourite: _favourite,
    );
    try {
      ref.read(hostsProvider.notifier).save(host);
    } catch (e) {
      setState(() => _error = e is String ? e : e.toString());
      return;
    }
    context.go('/hosts');
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
    final brightness = Theme.of(context).brightness;

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
                            controller: _port,
                            style: monoStyle(context, size: 14),
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Port'),
                            validator: (v) {
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
                      decoration: const InputDecoration(labelText: 'User'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Needed' : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Authentication',
                  children: [
                    SegmentedButton<_AuthChoice>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: _AuthChoice.password, label: Text('Password')),
                        ButtonSegment(value: _AuthChoice.key, label: Text('Key')),
                        ButtonSegment(value: _AuthChoice.agent, label: Text('Agent')),
                        ButtonSegment(value: _AuthChoice.ask, label: Text('Ask each time')),
                      ],
                      selected: {_auth},
                      onSelectionChanged: (s) => setState(() => _auth = s.first),
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
                              decoration: const InputDecoration(labelText: 'Key'),
                              items: [
                                for (final i in identities)
                                  DropdownMenuItem(value: i.id, child: Text('${i.label} (${i.keyType})')),
                              ],
                              onChanged: (v) => setState(() => _identityId = v),
                            ),
                    if (_auth == _AuthChoice.ask)
                      Text(
                        'The server decides: a password prompt, a two-factor code, or both.',
                        style: TextStyle(color: t.muted, fontSize: 13),
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
                            decoration: const InputDecoration(labelText: 'Group'),
                            items: [
                              const DropdownMenuItem<String?>(value: null, child: Text('No group')),
                              for (final g in groups) DropdownMenuItem(value: g.id, child: Text(g.label)),
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
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Advanced',
                  children: [
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
