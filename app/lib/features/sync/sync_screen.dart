import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/engine/engine.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/inheritance.dart';
import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../shell/empty_state.dart';
import 'sync_providers.dart';

/// Where the vault lives and how it is doing. Before setup this is the
/// wizard: pick a place, pick a passphrase, write the recovery code down.
class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider).value;
    final pending = ref.watch(pendingRecoveryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Sync',
          leading: IconButton(
            tooltip: 'Back to settings',
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        Expanded(
          child: pending != null
              ? RecoveryPanel(
                  result: pending,
                  onDone: () {
                    ref.read(pendingRecoveryProvider.notifier).set(null);
                    context.go('/settings');
                  },
                )
              : status == null
                  ? const Center(child: CircularProgressIndicator())
                  : status.configured
                      ? _ConfiguredView(status: status)
                      : const SetupWizard(),
        ),
      ],
    );
  }
}

// ---- Setup -----------------------------------------------------------------

enum _Place { folder, sftp, none }

enum _Step { place, folder, server, create, join }

class SetupWizard extends ConsumerStatefulWidget {
  const SetupWizard({super.key});

  @override
  ConsumerState<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends ConsumerState<SetupWizard> {
  _Step _step = _Step.place;
  _Place _place = _Place.folder;
  late final TextEditingController _path = TextEditingController(text: _defaultFolder());
  late final TextEditingController _name = TextEditingController(text: _defaultName());
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  final _remote = TextEditingController(text: 'Promptly Vault');
  String? _hostId;
  bool _useCode = false;
  bool _busy = false;
  String? _error;

  String _defaultFolder() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    return home.isEmpty ? 'Promptly Vault' : '$home/Promptly Vault';
  }

  String _defaultName() {
    try {
      return ref.read(engineProvider).syncDefaultDeviceName();
    } catch (_) {
      return 'This device';
    }
  }

  @override
  void dispose() {
    _path.dispose();
    _name.dispose();
    _pass.dispose();
    _confirm.dispose();
    _code.dispose();
    _remote.dispose();
    super.dispose();
  }

  void _continueFromPlace() {
    switch (_place) {
      case _Place.folder:
        setState(() => _step = _Step.folder);
      case _Place.sftp:
        setState(() => _step = _Step.server);
      case _Place.none:
        context.go('/settings');
    }
  }

  void _continueFromFolder() {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Pick a folder.');
      return;
    }
    final exists = ref.read(engineProvider).syncFolderHasVault(path);
    setState(() {
      _error = null;
      _step = exists ? _Step.join : _Step.create;
    });
  }

  Future<void> _continueFromServer() async {
    final hostId = _hostId;
    if (hostId == null) {
      setState(() => _error = 'Pick a host.');
      return;
    }
    if (_remote.text.trim().isEmpty) {
      setState(() => _error = 'Name a folder on the server.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final exists = await ref.read(engineProvider).syncSftpFolderHasVault(hostId, _remote.text.trim());
      setState(() => _step = exists ? _Step.join : _Step.create);
    } catch (e) {
      setState(() => _error = e is String ? e : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (_pass.text.length < 8) {
      setState(() => _error = 'Use a passphrase of at least eight characters.');
      return;
    }
    if (_pass.text != _confirm.text) {
      setState(() => _error = 'The two passphrases differ.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final engine = ref.read(engineProvider);
      final result = _place == _Place.sftp
          ? await engine.syncCreateSftp(_hostId!, _remote.text.trim(), _pass.text, _name.text.trim())
          : await engine.syncCreateLocalFolder(_path.text.trim(), _pass.text, _name.text.trim());
      // Shown by the screen above, so it survives the status flipping to configured.
      ref.read(pendingRecoveryProvider.notifier).set(result);
    } catch (e) {
      setState(() => _error = e is String ? e : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final engine = ref.read(engineProvider);
      if (_place == _Place.sftp) {
        await engine.syncJoinSftp(
          _hostId!,
          _remote.text.trim(),
          passphrase: _useCode ? null : _pass.text,
          recoveryCode: _useCode ? _code.text : null,
          deviceName: _name.text.trim(),
        );
      } else {
        await engine.syncJoinLocalFolder(
          _path.text.trim(),
          passphrase: _useCode ? null : _pass.text,
          recoveryCode: _useCode ? _code.text : null,
          deviceName: _name.text.trim(),
        );
      }
      // The status stream flips the screen to the configured view.
    } catch (e) {
      setState(() => _error = e is String ? e : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...switch (_step) {
              _Step.place => _placeStep(t),
              _Step.folder => _folderStep(t),
              _Step.server => _serverStep(t),
              _Step.create => _createStep(t),
              _Step.join => _joinStep(t),
            },
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, key: const Key('sync-error'), style: TextStyle(color: t.danger, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _placeStep(PromptlyTokens t) => [
        Text('Where should Promptly keep your vault?',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: t.text, letterSpacing: -0.3)),
        const SizedBox(height: 8),
        Text(
          'A small encrypted folder with your hosts, keys and snippets. It is locked on this device before it goes anywhere, and Promptly never runs a server.',
          style: TextStyle(color: t.muted, height: 1.45),
        ),
        const SizedBox(height: 18),
        _PlaceOption(
          key: const Key('sync-option-folder'),
          icon: Icons.folder_outlined,
          name: 'A folder on this computer',
          description:
              'Point it at a folder that Syncthing, Dropbox, iCloud Drive, Google Drive or any other sync client mirrors. The transport is theirs; the encryption is ours.',
          selected: _place == _Place.folder,
          onTap: () => setState(() => _place = _Place.folder),
        ),
        const SizedBox(height: 8),
        _PlaceOption(
          key: const Key('sync-option-sftp'),
          icon: Icons.dns_outlined,
          name: 'Your own server',
          description: 'SFTP to a host you already have in Promptly, with its saved password or key. Zero new accounts.',
          selected: _place == _Place.sftp,
          onTap: () => setState(() => _place = _Place.sftp),
        ),
        const SizedBox(height: 8),
        _PlaceOption(
          key: const Key('sync-option-none'),
          icon: Icons.computer_outlined,
          name: 'This device only',
          description: 'No sync for now. You can turn it on later.',
          selected: _place == _Place.none,
          onTap: () => setState(() => _place = _Place.none),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
          ),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 18, color: t.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'A whole vault is usually under 100 KB. Every option has a free tier thousands of times bigger. This costs you nothing, ever.',
                  style: TextStyle(fontSize: 12, color: t.muted, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(key: const Key('sync-continue'), onPressed: _continueFromPlace, child: const Text('Continue')),
      ];

  List<Widget> _folderStep(PromptlyTokens t) => [
        _Heading('Which folder?'),
        const SizedBox(height: 8),
        Text(
          'An empty folder starts a new vault. A folder that already holds one lets this device join it.',
          style: TextStyle(color: t.muted, height: 1.45),
        ),
        const SizedBox(height: 16),
        _Label('Folder'),
        TextField(
          key: const Key('sync-path'),
          controller: _path,
          style: monoStyle(context, size: 13),
          decoration: const InputDecoration(hintText: '/home/you/Promptly Vault'),
        ),
        const SizedBox(height: 12),
        _Label('This device is called'),
        TextField(
          key: const Key('sync-device-name'),
          controller: _name,
          decoration: const InputDecoration(hintText: 'Work laptop'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(onPressed: () => setState(() => _step = _Step.place), child: const Text('Back')),
            const SizedBox(width: 8),
            FilledButton(key: const Key('sync-folder-continue'), onPressed: _continueFromFolder, child: const Text('Continue')),
          ],
        ),
      ];

  List<Widget> _serverStep(PromptlyTokens t) {
    final groups = ref.watch(groupsProvider);
    // A key from the host's group counts, as it does when sync connects.
    final hosts = ref.watch(hostsProvider).where((h) {
      final auth = Inherited(h, groups).auth;
      return auth.kind == AuthKind.identity || (auth.kind == AuthKind.password && auth.passwordSecretId != null);
    }).toList();
    return [
      const _Heading('Which server?'),
      const SizedBox(height: 8),
      Text(
        'A host you have saved with a password or a key. Promptly keeps the vault in a folder in that login\'s home over SFTP, and uses the saved login for every sync. Connect to it in the terminal once first, so its host key is trusted.',
        style: TextStyle(color: t.muted, height: 1.45),
      ),
      const SizedBox(height: 16),
      const _Label('Host'),
      if (hosts.isEmpty)
        Text(
          'No saved host has a stored password or key yet. Add one on the Hosts tab, with "remember" ticked or a key picked.',
          style: TextStyle(color: t.warning, fontSize: 13),
        )
      else
        DropdownButtonFormField<String>(
          key: const Key('sync-host'),
          initialValue: _hostId,
          hint: const Text('Pick a host'),
          items: [
            for (final h in hosts)
              DropdownMenuItem(
                value: h.id,
                child: Text('${h.label}  ·  ${h.username}@${h.hostname}', style: monoStyle(context, size: 13)),
              ),
          ],
          onChanged: (v) => setState(() => _hostId = v),
        ),
      const SizedBox(height: 12),
      const _Label('Folder on the server'),
      TextField(
        key: const Key('sync-remote'),
        controller: _remote,
        style: monoStyle(context, size: 13),
        decoration: const InputDecoration(hintText: 'Promptly Vault'),
      ),
      const SizedBox(height: 12),
      const _Label('This device is called'),
      TextField(
        key: const Key('sync-device-name'),
        controller: _name,
        decoration: const InputDecoration(hintText: 'Work laptop'),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          OutlinedButton(onPressed: _busy ? null : () => setState(() => _step = _Step.place), child: const Text('Back')),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('sync-server-continue'),
            onPressed: _busy || hosts.isEmpty ? null : _continueFromServer,
            child: Text(_busy ? 'Connecting…' : 'Continue'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _createStep(PromptlyTokens t) => [
        _Heading('Choose a passphrase'),
        const SizedBox(height: 8),
        Text(
          'It locks the vault. Promptly cannot reset it: if you forget it, only the recovery code on the next screen can open the vault. Pick something long you will remember.',
          style: TextStyle(color: t.muted, height: 1.45),
        ),
        const SizedBox(height: 16),
        _Label('Passphrase'),
        TextField(key: const Key('sync-passphrase'), controller: _pass, obscureText: true, autofocus: true),
        const SizedBox(height: 12),
        _Label('Again'),
        TextField(
          key: const Key('sync-passphrase-confirm'),
          controller: _confirm,
          obscureText: true,
          onSubmitted: (_) => _create(),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(onPressed: _busy ? null : () => setState(() => _step = _place == _Place.sftp ? _Step.server : _Step.folder), child: const Text('Back')),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('sync-create'),
              onPressed: _busy ? null : _create,
              child: Text(_busy ? 'Creating…' : 'Create the vault'),
            ),
          ],
        ),
      ];

  List<Widget> _joinStep(PromptlyTokens t) => [
        _Heading('This folder already holds a vault'),
        const SizedBox(height: 8),
        Text(
          _useCode
              ? 'Type the recovery code you wrote down when the vault was made.'
              : 'Type its passphrase and this device joins it.',
          style: TextStyle(color: t.muted, height: 1.45),
        ),
        const SizedBox(height: 16),
        if (_useCode) ...[
          _Label('Recovery code'),
          TextField(
            key: const Key('sync-recovery-input'),
            controller: _code,
            autofocus: true,
            style: monoStyle(context, size: 14),
            decoration: const InputDecoration(hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX'),
            onSubmitted: (_) => _join(),
          ),
        ] else ...[
          _Label('Passphrase'),
          TextField(
            key: const Key('sync-join-passphrase'),
            controller: _pass,
            obscureText: true,
            autofocus: true,
            onSubmitted: (_) => _join(),
          ),
        ],
        TextButton(
          onPressed: () => setState(() => _useCode = !_useCode),
          child: Text(_useCode ? 'Use the passphrase instead' : 'Use a recovery code instead'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton(onPressed: _busy ? null : () => setState(() => _step = _place == _Place.sftp ? _Step.server : _Step.folder), child: const Text('Back')),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('sync-join'),
              onPressed: _busy ? null : _join,
              child: Text(_busy ? 'Joining…' : 'Join the vault'),
            ),
          ],
        ),
      ];
}

/// The recovery code, shown once, with a checkbox standing between the
/// person and the Done button.
class RecoveryPanel extends StatefulWidget {
  const RecoveryPanel({super.key, required this.result, required this.onDone});

  final SyncSetupResult result;
  final VoidCallback onDone;

  @override
  State<RecoveryPanel> createState() => _RecoveryPanelState();
}

class _RecoveryPanelState extends State<RecoveryPanel> {
  bool _wroteDown = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Heading('Write this down'),
            const SizedBox(height: 8),
            Text(
              'This recovery code opens the vault if you ever forget the passphrase. Promptly does not keep it and cannot show it again. Put it somewhere safe, away from this device.',
              style: TextStyle(color: t.muted, height: 1.45),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.accent, width: 1.5),
                borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.result.recoveryCode,
                      key: const Key('sync-recovery-code'),
                      style: monoStyle(context, size: 18, weight: FontWeight.w600, color: t.text),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: widget.result.recoveryCode));
                      if (context.mounted) notYet(context, 'Copied. Paste it somewhere safe, then clear the clipboard.');
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              key: const Key('sync-wrote-it-down'),
              value: _wroteDown,
              onChanged: (v) => setState(() => _wroteDown = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('I have written it down somewhere safe'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('sync-done'),
              onPressed: _wroteDown ? widget.onDone : null,
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: context.tokens.text, letterSpacing: -0.3),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.tokens.muted)),
      );
}

class _PlaceOption extends StatelessWidget {
  const _PlaceOption({
    super.key,
    required this.icon,
    required this.name,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String name;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: selected ? t.accent : t.border, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? t.accent : t.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: TextStyle(fontWeight: FontWeight.w600, color: t.text)),
                  const SizedBox(height: 2),
                  Text(description, style: TextStyle(fontSize: 12, color: t.muted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? t.accent : t.muted),
          ],
        ),
      ),
    );
  }
}

// ---- Configured ------------------------------------------------------------

class _ConfiguredView extends ConsumerWidget {
  const _ConfiguredView({required this.status});

  final SyncStatus status;

  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(engineProvider).syncNow();
    } catch (e) {
      if (context.mounted) notYet(context, 'Sync failed: $e');
    }
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect this device?'),
        content: const Text(
          'Your hosts, keys and snippets stay on this device and keep working. They just stop syncing until you set the vault up again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok == true) {
      try {
        ref.read(engineProvider).syncDisconnect();
      } catch (e) {
        if (context.mounted) notYet(context, 'Could not disconnect: $e');
      }
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, SyncDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text(
          'Its folder in the vault is deleted after everything it had is kept in a snapshot from this device. This does not lock the device out: it keeps the key to the vault, even if you change the passphrase. If it was lost or stolen, cut off its access to where the vault lives, and change the passwords and keys it had.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await ref.read(engineProvider).syncRemoveDevice(d.id);
      } catch (e) {
        if (context.mounted) notYet(context, 'Could not remove: $e');
      }
    }
  }

  void _showQr(BuildContext context, WidgetRef ref) {
    final payload = ref.read(engineProvider).syncQrPayload();
    if (payload == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enrol another device'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: payload, size: 240),
              ),
              const SizedBox(height: 12),
              const Text(
                'Scan this with Promptly on the other device. Whoever photographs it can read the vault, so show it only to your own device. Scanning lands with the phone builds; until then, join with the passphrase.',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final kb = (status.vaultBytes / 1024).toStringAsFixed(status.vaultBytes < 10240 ? 1 : 0);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      status.lastError != null ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                      color: status.lastError != null ? t.warning : t.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        syncSummary(status),
                        key: const Key('sync-summary'),
                        style: TextStyle(fontWeight: FontWeight.w600, color: t.text),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('sync-now'),
                      onPressed: status.syncing ? null : () => _syncNow(context, ref),
                      icon: const Icon(Icons.sync, size: 16),
                      label: const Text('Sync now'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _Row('Where', status.location ?? '', mono: true),
                _Row('This device', status.deviceName),
                _Row('Vault size', '$kb KB · ${status.pendingOps} change${status.pendingOps == 1 ? '' : 's'} waiting'),
                if (status.recoveryHint != null) _Row('Recovery code starts with', status.recoveryHint!, mono: true),
                for (final w in status.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(w, style: TextStyle(fontSize: 12, color: t.warning)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text('DEVICES', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.muted)),
        ),
        Card(
          child: Column(
            children: [
              for (final d in status.devices)
                ListTile(
                  leading: Icon(_platformIcon(d.platform), color: d.isThisDevice ? t.accent : t.muted),
                  title: Text(d.name),
                  subtitle: Text(
                    '${d.platform} · since ${DateTime.tryParse(d.enrolledAt)?.toLocal().toString().split(' ').first ?? d.enrolledAt}'
                    '${d.isThisDevice ? ' · this device' : ''}',
                  ),
                  trailing: d.isThisDevice
                      ? null
                      : IconButton(
                          tooltip: 'Remove device',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _remove(context, ref, d),
                        ),
                ),
              ListTile(
                leading: Icon(Icons.qr_code_2, color: t.muted),
                title: const Text('Add another device'),
                subtitle: const Text('Show a code to scan, or join from the other device with the passphrase.'),
                trailing: TextButton(onPressed: () => _showQr(context, ref), child: const Text('Show code')),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('sync-disconnect'),
            style: TextButton.styleFrom(foregroundColor: t.danger),
            onPressed: () => _disconnect(context, ref),
            icon: const Icon(Icons.link_off, size: 18),
            label: const Text('Disconnect this device'),
          ),
        ),
      ],
    );
  }

  IconData _platformIcon(String platform) => switch (platform) {
        'android' || 'ios' => Icons.smartphone,
        _ => Icons.computer_outlined,
      };
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.mono = false});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 180, child: Text(label, style: TextStyle(fontSize: 13, color: t.muted))),
          Expanded(
            child: Text(
              value,
              style: mono ? monoStyle(context, size: 13, color: t.text) : TextStyle(fontSize: 13, color: t.text),
            ),
          ),
        ],
      ),
    );
  }
}
