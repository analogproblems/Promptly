import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/engine/engine.dart';
import '../../core/file_picker.dart';
import '../../core/theme/theme.dart';
import '../../core/theme/tokens.dart';
import '../hosts/models.dart';
import '../hosts/repositories.dart';
import '../lock/app_lock.dart';
import '../sessions/session_manager.dart';
import '../settings/settings_providers.dart';
import '../shell/empty_state.dart';

/// The public key as a QR code, for a phone or another device to read.
class PublicKeyQrDialog extends StatelessWidget {
  const PublicKeyQrDialog({super.key, required this.identity});

  final Identity identity;

  @override
  Widget build(BuildContext context) {
    // What is left of a phone's width inside the dialog, so the code fits.
    final size = math.min(240.0, MediaQuery.sizeOf(context).width - 160);
    return AlertDialog(
      title: Text(identity.label),
      scrollable: true,
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const Key('key-qr'),
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              // A fixed size, so the dialog can measure it.
              child: SizedBox.square(
                dimension: size,
                child: QrImageView(data: identity.publicKey, size: size, padding: EdgeInsets.zero),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'This is the public half of the key only, so it is safe to show. '
              'Scan it where the key should be trusted.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: identity.publicKey));
            notYet(context, 'Public key copied.');
          },
          child: const Text('Copy'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

/// "Install on host", the ssh-copy-id flow: pick a saved host, log in with
/// its saved login (or a password typed here when it has none), and add
/// the public key to `~/.ssh/authorized_keys` there.
class InstallKeyDialog extends ConsumerStatefulWidget {
  const InstallKeyDialog({super.key, required this.identity});

  final Identity identity;

  @override
  ConsumerState<InstallKeyDialog> createState() => _InstallKeyDialogState();
}

class _InstallKeyDialogState extends ConsumerState<InstallKeyDialog> {
  String? _hostId;
  final _password = TextEditingController();
  bool _busy = false;
  String? _done;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// The host's request, and whether it has no saved login to use, so a
  /// password must be typed.
  ({SshConnectRequest? request, String? problem, bool needsPassword}) _plan(Host host) {
    final plan = ref.read(sessionManagerProvider.notifier).requestFor(host, theme: terminalThemeFor(ref, context));
    final r = plan.request;
    final needsPassword =
        r != null && (r.auth == SshAuthKind.interactive || (r.auth == SshAuthKind.password && r.password == null));
    return (request: r, problem: plan.problem, needsPassword: needsPassword);
  }

  Future<void> _install(Host host) async {
    final plan = _plan(host);
    var request = plan.request;
    if (request == null) {
      setState(() => _error = plan.problem ?? 'This host cannot be used.');
      return;
    }
    if (plan.needsPassword) {
      if (_password.text.isEmpty) {
        setState(() => _error = 'Type the password for ${host.label}.');
        return;
      }
      request = copyRequest(request, auth: SshAuthKind.password, password: _password.text);
    }
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    final engine = ref.read(engineProvider);
    // Logging in with a saved key is using it: the same check as connecting.
    final usesKey = request.privateKey != null || request.jumps.any((j) => j.privateKey != null);
    if (usesKey && !await ref.read(appLockProvider.notifier).unlockKeys()) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The SSH key for ${host.label} stays locked, so nothing was installed.';
        });
      }
      return;
    }
    try {
      final message = await engine.sshInstallPublicKey(request, widget.identity.publicKey);
      if (mounted) setState(() => _done = message);
    } catch (e) {
      if (mounted) setState(() => _error = e is String ? e : e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hosts = ref.watch(hostsProvider);
    Host? host;
    for (final h in hosts) {
      if (h.id == _hostId) host = h;
    }
    final needsPassword = host != null && _plan(host).needsPassword;
    return AlertDialog(
      title: Text('Install ${widget.identity.label} on a host'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Promptly logs in to the host and adds this public key to ~/.ssh/authorized_keys there, '
              'so the host lets this key in from then on. A key already there is not added twice.',
              style: TextStyle(color: t.muted, height: 1.4),
            ),
            const SizedBox(height: 14),
            if (hosts.isEmpty)
              Text('No saved hosts yet. Add one on the Hosts tab first.', style: TextStyle(color: t.warning))
            else
              DropdownButtonFormField<String>(
                key: const Key('install-host'),
                initialValue: _hostId,
                isExpanded: true,
                hint: const Text('Pick a host'),
                items: [
                  for (final h in hosts)
                    DropdownMenuItem(
                      value: h.id,
                      child: Text(
                        '${h.label} · ${h.username}@${h.hostname}',
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(context, size: 13),
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                          _hostId = v;
                          _done = null;
                          _error = null;
                        }),
              ),
            if (needsPassword) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('install-password'),
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(labelText: 'Password for ${host.username}@${host.hostname}'),
                onSubmitted: (_) => _install(host!),
              ),
            ],
            if (_done != null) ...[
              const SizedBox(height: 12),
              Text(_done!, key: const Key('install-result'), style: TextStyle(color: t.accent, height: 1.4)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, key: const Key('install-error'), style: TextStyle(color: t.danger, height: 1.4)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_done != null ? 'Done' : 'Cancel')),
        FilledButton(
          key: const Key('install-go'),
          onPressed: host == null || _busy ? null : () => _install(host!),
          child: Text(_busy ? 'Installing…' : 'Install'),
        ),
      ],
    );
  }
}

/// Export the private key, behind a warning that must be ticked. As
/// stored, or locked with a new passphrase; copied, or saved to a file
/// where the system has a save dialog.
class ExportKeyDialog extends ConsumerStatefulWidget {
  const ExportKeyDialog({super.key, required this.identity});

  final Identity identity;

  @override
  ConsumerState<ExportKeyDialog> createState() => _ExportKeyDialogState();
}

class _ExportKeyDialogState extends ConsumerState<ExportKeyDialog> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  bool _understood = false;
  bool _relock = false;
  String? _error;

  late final String? _privateKey = _read();
  late final bool _locked = _isLocked();
  late final String? _saved = ref.read(identitiesProvider.notifier).passphraseFor(widget.identity);

  String? _read() {
    final id = widget.identity.privateKeySecretId;
    if (id == null) return null;
    try {
      return ref.read(engineProvider).secretGet(id);
    } catch (_) {
      return null;
    }
  }

  bool _isLocked() {
    final key = _privateKey;
    if (key == null) return false;
    try {
      return ref.read(engineProvider).keyInspect(key, null).encrypted;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  /// The text to hand over, or null with the reason shown.
  String? _text() {
    final key = _privateKey!;
    if (!_relock) return key;
    if (_new.text.isEmpty) {
      setState(() => _error = 'Choose a new passphrase.');
      return null;
    }
    if (_new.text != _again.text) {
      setState(() => _error = 'The two new passphrases differ.');
      return null;
    }
    try {
      return ref.read(engineProvider).keyExport(
            key,
            passphrase: _locked ? (_saved ?? _current.text) : null,
            newPassphrase: _new.text,
          );
    } catch (e) {
      setState(() => _error = e is String ? e : e.toString());
      return null;
    }
  }

  void _copy() {
    final text = _text();
    if (text == null) return;
    Clipboard.setData(ClipboardData(text: text));
    Navigator.pop(context);
    notYet(context, 'Private key copied. Paste it where it goes, then copy something else over it.');
  }

  Future<void> _save(SaveTextFile save) async {
    final text = _text();
    if (text == null) return;
    final name = widget.identity.label.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    try {
      final path = await save(suggestedName: name.isEmpty ? 'id_${widget.identity.keyType}' : name, text: text);
      if (path == null || !mounted) return;
      Navigator.pop(context);
      notYet(context, 'Saved to $path.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save it: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final save = ref.watch(fileSaverProvider);
    final ready = _understood && _privateKey != null;
    return AlertDialog(
      title: Text('Export ${widget.identity.label}'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: t.danger),
                borderRadius: BorderRadius.circular(PromptlyTokens.panelRadius),
              ),
              child: Text(
                'This is the private key. Anyone who gets a copy can log in as you wherever it is installed. '
                'Keep it somewhere only you can reach, and never send it to anyone.',
                style: TextStyle(color: t.text, height: 1.4),
              ),
            ),
            const SizedBox(height: 12),
            if (_privateKey == null)
              Text('The private key is not on this device.', style: TextStyle(color: t.danger))
            else ...[
              Text(
                _locked
                    ? 'As stored, it is locked with its passphrase.'
                    : 'As stored, it has no passphrase: whoever has the copy can use it straight away.',
                style: TextStyle(color: t.muted, height: 1.4),
              ),
              SwitchListTile(
                key: const Key('export-relock'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Lock the copy with a new passphrase'),
                value: _relock,
                onChanged: (v) => setState(() {
                  _relock = v;
                  _error = null;
                }),
              ),
              if (_relock) ...[
                if (_locked && _saved == null) ...[
                  TextField(
                    key: const Key('export-current'),
                    controller: _current,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Its passphrase now'),
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  key: const Key('export-new'),
                  controller: _new,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New passphrase'),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('export-again'),
                  controller: _again,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Again'),
                ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('export-understood'),
                value: _understood,
                onChanged: (v) => setState(() => _understood = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('I understand that anyone with the copy can use this key'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, key: const Key('export-error'), style: TextStyle(color: t.danger, height: 1.4)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        OutlinedButton(key: const Key('export-copy'), onPressed: ready ? _copy : null, child: const Text('Copy')),
        if (save != null)
          FilledButton(
            key: const Key('export-save'),
            onPressed: ready ? () => _save(save) : null,
            child: const Text('Save to a file…'),
          ),
      ],
    );
  }
}
