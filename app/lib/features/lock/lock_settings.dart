import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import 'app_lock.dart';

/// The Security rows in Settings: locking the app, unlocking keys, and the
/// app passcode where the system has no check of its own.
class LockSettingsCard extends ConsumerWidget {
  const LockSettingsCard({super.key});

  static const lockTimes = [0, 1, 5, 15, 60];

  static String lockTimeLabel(int minutes) => switch (minutes) {
        0 => 'Every time',
        1 => 'After 1 minute',
        60 => 'After 1 hour',
        final m => 'After $m minutes',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final state = ref.watch(appLockProvider);
    final lock = ref.read(appLockProvider.notifier);
    final s = state.settings;
    final system = state.systemAvailable;
    final how = system == true
        ? 'your fingerprint, face or device PIN'
        : s.passcodeHash != null
            ? 'the app passcode'
            : null;
    final noCheck = system == false && s.passcodeHash == null;
    return Column(
      children: [
        SwitchListTile(
          key: const Key('key-unlock'),
          title: const Text('Unlock SSH keys before use'),
          subtitle: Text(
            noCheck
                ? 'Needs an app passcode on this device. Set one below.'
                : 'Asks for ${how ?? 'your fingerprint or PIN'} before connecting with a key. Sync doesn\'t ask.',
          ),
          value: s.keyUnlock && !noCheck,
          onChanged: noCheck ? null : lock.setKeyUnlock,
        ),
        SwitchListTile(
          key: const Key('app-lock'),
          title: const Text('Lock Promptly'),
          subtitle: Text(
            noCheck
                ? 'Needs an app passcode on this device. Set one below.'
                : 'Asks for ${how ?? 'your fingerprint or PIN'} when you open or return to Promptly.',
          ),
          value: s.appLock && !noCheck,
          onChanged: noCheck ? null : lock.setAppLock,
        ),
        ListTile(
          title: const Text('Ask again'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('How long a check lasts before Promptly asks again.'),
              DropdownButton<int>(
                key: const Key('lock-after'),
                isExpanded: true,
                value: lockTimes.contains(s.lockAfterMinutes) ? s.lockAfterMinutes : 5,
                items: [for (final m in lockTimes) DropdownMenuItem(value: m, child: Text(lockTimeLabel(m)))],
                onChanged: (m) {
                  if (m != null) lock.setLockAfter(m);
                },
              ),
            ],
          ),
        ),
        if (system == false)
          ListTile(
            key: const Key('app-passcode-setting'),
            title: Text(s.passcodeHash == null ? 'Set an app passcode' : 'App passcode'),
            subtitle: Text(
              s.passcodeHash == null
                  ? 'For devices without a fingerprint or PIN check.'
                  : 'Set. Stored only as a hash on this device.',
              style: TextStyle(color: t.muted),
            ),
            trailing: s.passcodeHash == null
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    tooltip: 'Remove the passcode',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: lock.clearPasscode,
                  ),
            onTap: s.passcodeHash == null ? () => _setPasscode(context, ref) : null,
          ),
      ],
    );
  }

  Future<void> _setPasscode(BuildContext context, WidgetRef ref) async {
    final passcode = await showDialog<String>(context: context, builder: (_) => const _NewPasscodeDialog());
    if (passcode != null) await ref.read(appLockProvider.notifier).setPasscode(passcode);
  }
}

class _NewPasscodeDialog extends StatefulWidget {
  const _NewPasscodeDialog();

  @override
  State<_NewPasscodeDialog> createState() => _NewPasscodeDialogState();
}

class _NewPasscodeDialogState extends State<_NewPasscodeDialog> {
  final _first = TextEditingController();
  final _again = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _first.dispose();
    _again.dispose();
    super.dispose();
  }

  void _save() {
    if (_first.text.length < 4) {
      setState(() => _problem = 'Use at least four characters.');
    } else if (_first.text != _again.text) {
      setState(() => _problem = 'The two passcodes are different.');
    } else {
      Navigator.of(context).pop(_first.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set an app passcode'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('new-passcode'),
            controller: _first,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Passcode'),
          ),
          TextField(
            key: const Key('new-passcode-again'),
            controller: _again,
            obscureText: true,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(labelText: 'Same again', errorText: _problem),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const Key('new-passcode-save'), onPressed: _save, child: const Text('Set passcode')),
      ],
    );
  }
}
