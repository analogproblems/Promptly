import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';
import '../../core/file_picker.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../lock/app_lock.dart';
import '../shell/empty_state.dart';
import 'key_actions.dart';

class KeysScreen extends ConsumerWidget {
  const KeysScreen({super.key});

  Future<void> _generate(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<({String label, SshKeyKind kind, bool localOnly})>(
      context: context,
      builder: (_) => const _GenerateDialog(),
    );
    if (result == null || !context.mounted) return;
    try {
      ref
          .read(identitiesProvider.notifier)
          .generate(label: result.label, kind: result.kind, localOnly: result.localOnly);
      notYet(context, 'Generated ${result.label}.');
    } catch (e) {
      notYet(context, 'Could not generate a key: $e');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(context: context, builder: (_) => const _ImportDialog());
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Identity identity) async {
    final users = ref.read(hostsProvider).where((h) => h.auth.identityId == identity.id).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${identity.label}?'),
        content: Text(
          users.isEmpty
              ? 'The private key is removed from this device. This cannot be undone.'
              : '${users.length} host${users.length == 1 ? ' uses' : 's use'} this key and will need another way to log in. The private key is removed from this device. This cannot be undone.',
        ),
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
    if (ok == true) ref.read(identitiesProvider.notifier).delete(identity.id);
  }

  /// The private key is shown only after the same check as using it.
  Future<void> _export(BuildContext context, WidgetRef ref, Identity identity) async {
    if (!await ref.read(appLockProvider.notifier).unlockKeys()) {
      if (context.mounted) notYet(context, 'The key stays locked, so it was not exported.');
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(context: context, builder: (_) => ExportKeyDialog(identity: identity));
  }

  void _forgetPassphrase(BuildContext context, WidgetRef ref, Identity identity) {
    try {
      ref.read(identitiesProvider.notifier).forgetPassphrase(identity.id);
      notYet(context, 'The passphrase for ${identity.label} is forgotten. It is asked for when you next connect.');
    } catch (e) {
      notYet(context, 'Could not forget it: $e');
    }
  }

  void _setLocalOnly(BuildContext context, WidgetRef ref, Identity identity, bool localOnly) {
    try {
      ref.read(identitiesProvider.notifier).setLocalOnly(identity.id, localOnly);
      notYet(
        context,
        localOnly
            ? '${identity.label} stays on this device only. It is removed from the vault and your other devices.'
            : '${identity.label} syncs with the vault again.',
      );
    } catch (e) {
      notYet(context, 'Could not change it: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identities = ref.watch(identitiesProvider);
    final engine = ref.watch(engineProvider);
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Keys',
          // Wraps on a narrow phone at large text instead of overflowing.
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _import(context, ref),
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Import'),
              ),
              FilledButton.icon(
                key: const Key('keys-generate'),
                onPressed: () => _generate(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Generate'),
              ),
            ],
          ),
        ),
        Expanded(
          child: identities.isEmpty
              ? EmptyState(
                  icon: Icons.key_outlined,
                  title: 'No keys yet',
                  message: 'Generate an ed25519 key in one tap, or import one you already have. '
                      'Private keys are kept encrypted. With sync on they also go to your other devices, '
                      'encrypted in the vault, unless you keep a key on this device only.',
                  action: OutlinedButton.icon(
                    onPressed: () => _generate(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Generate key'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  itemCount: identities.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final id = identities[i];
                    String fingerprint;
                    try {
                      fingerprint = engine.keyFingerprint(id.publicKey);
                    } catch (_) {
                      fingerprint = 'fingerprint unavailable';
                    }
                    return Card(
                      child: ListTile(
                        leading: Icon(Icons.key_outlined, color: t.accent),
                        title: Text(id.label, style: monoStyle(context, size: 14, weight: FontWeight.w600)),
                        subtitle: Text(
                          '${id.keyType.toUpperCase()}${id.localOnly ? ' · this device only' : ''}'
                          '${id.passphraseSecretId != null ? ' · passphrase saved' : ''} · $fingerprint',
                          style: monoStyle(context, size: 11, color: t.muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Key actions',
                          onSelected: (v) {
                            switch (v) {
                              case 'copy':
                                Clipboard.setData(ClipboardData(text: id.publicKey));
                                notYet(context, 'Public key copied.');
                              case 'qr':
                                showDialog<void>(context: context, builder: (_) => PublicKeyQrDialog(identity: id));
                              case 'install':
                                showDialog<void>(context: context, builder: (_) => InstallKeyDialog(identity: id));
                              case 'export':
                                _export(context, ref, id);
                              case 'forget':
                                _forgetPassphrase(context, ref, id);
                              case 'local':
                                _setLocalOnly(context, ref, id, !id.localOnly);
                              case 'delete':
                                _delete(context, ref, id);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'copy', child: Text('Copy public key')),
                            const PopupMenuItem(
                              key: Key('key-show-qr'),
                              value: 'qr',
                              child: Text('Show public key as QR code'),
                            ),
                            const PopupMenuItem(
                              key: Key('key-install'),
                              value: 'install',
                              child: Text('Install on a host…'),
                            ),
                            const PopupMenuItem(
                              key: Key('key-export'),
                              value: 'export',
                              child: Text('Export private key…'),
                            ),
                            if (id.passphraseSecretId != null)
                              const PopupMenuItem(
                                key: Key('key-forget-passphrase'),
                                value: 'forget',
                                child: Text('Forget saved passphrase'),
                              ),
                            PopupMenuItem(
                              key: const Key('key-toggle-local-only'),
                              value: 'local',
                              child: Text(id.localOnly ? 'Sync with the vault' : 'Keep on this device only'),
                            ),
                            const PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _GenerateDialog extends StatefulWidget {
  const _GenerateDialog();

  @override
  State<_GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends State<_GenerateDialog> {
  final _label = TextEditingController(text: 'promptly');
  SshKeyKind _kind = SshKeyKind.ed25519;
  bool _localOnly = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isEmpty) return;
    Navigator.pop(context, (label: label, kind: _kind, localOnly: _localOnly));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      title: const Text('Generate a key'),
      scrollable: true,
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('key-label'),
              controller: _label,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Name', hintText: 'laptop, work, homelab…'),
            ),
            const SizedBox(height: 14),
            Text(
              'Type',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.muted),
            ),
            RadioGroup<SshKeyKind>(
              groupValue: _kind,
              onChanged: (v) => setState(() => _kind = v ?? SshKeyKind.ed25519),
              child: const Column(
                children: [
                  RadioListTile(
                    value: SshKeyKind.ed25519,
                    title: Text('ed25519'),
                    subtitle: Text('Recommended. Small, fast, modern.'),
                    dense: true,
                  ),
                  RadioListTile(
                    value: SshKeyKind.ecdsaP256,
                    title: Text('ECDSA P-256'),
                    subtitle: Text('For servers that require it.'),
                    dense: true,
                  ),
                  RadioListTile(
                    value: SshKeyKind.rsa4096,
                    title: Text('RSA 4096'),
                    subtitle: Text('For old servers. Slow to generate.'),
                    dense: true,
                  ),
                ],
              ),
            ),
            SwitchListTile(
              key: const Key('key-local-only'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep on this device only'),
              subtitle: const Text('It is not synced. The private key stays here and never goes into the vault.'),
              value: _localOnly,
              onChanged: (v) => setState(() => _localOnly = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const Key('key-generate-ok'), onPressed: _submit, child: const Text('Generate')),
      ],
    );
  }
}

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _label = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  bool _localOnly = false;
  bool _remember = true;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final picked = await ref.read(filePickerProvider)(label: 'Private keys', extensions: const ['ppk', 'pem', 'key']);
    if (picked == null || !mounted) return;
    setState(() {
      _key.text = picked.text;
      if (_label.text.trim().isEmpty) _label.text = picked.name.replaceAll(RegExp(r'\.(ppk|pem|key)$'), '');
      _error = null;
    });
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isEmpty || _key.text.trim().isEmpty) {
      setState(() => _error = 'A name and the private key are both needed.');
      return;
    }
    try {
      ref
          .read(identitiesProvider.notifier)
          .import(
            label: label,
            privateKey: _key.text,
            passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
            localOnly: _localOnly,
            rememberPassphrase: _remember,
          );
      Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e is String ? e : e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      title: const Text('Import a private key'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _label,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('key-text'),
              controller: _key,
              maxLines: 6,
              style: monoStyle(context, size: 12),
              decoration: const InputDecoration(
                labelText: 'Private key',
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\nOpenSSH, PEM or PuTTY text',
                alignLabelWithHint: true,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('key-pick-file'),
                onPressed: _pickFile,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('Choose a file (.ppk, .pem, id_ed25519…)'),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('key-import-passphrase'),
              controller: _passphrase,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Passphrase, if the key has one'),
            ),
            if (_passphrase.text.isNotEmpty)
              SwitchListTile(
                key: const Key('key-import-remember'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Remember passphrase'),
                subtitle: const Text('Saved with the key, encrypted, so connecting does not ask for it.'),
                value: _remember,
                onChanged: (v) => setState(() => _remember = v),
              ),
            SwitchListTile(
              key: const Key('key-import-local-only'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep on this device only'),
              subtitle: const Text('It is not synced. The private key stays here and never goes into the vault.'),
              value: _localOnly,
              onChanged: (v) => setState(() => _localOnly = v),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: t.danger, fontSize: 13)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Import')),
      ],
    );
  }
}
