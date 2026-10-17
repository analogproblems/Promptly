import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router.dart';
import 'updates.dart';

/// With the setting on, looks for a new version a little after launch and
/// once a day after that, and says so once per version found.
class UpdateReminder extends ConsumerStatefulWidget {
  const UpdateReminder({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateReminder> createState() => _UpdateReminderState();
}

class _UpdateReminderState extends ConsumerState<UpdateReminder> {
  static const _firstCheck = Duration(seconds: 10);
  static const _every = Duration(days: 1);

  Timer? _timer;
  String? _told;

  @override
  void initState() {
    super.initState();
    if (updateChecksSupported && ref.read(updateCheckProvider)) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_firstCheck, () {
      _check();
      _timer = Timer.periodic(_every, (_) => _check());
    });
  }

  Future<void> _check() async {
    final release = await ref.read(updateProvider.notifier).check();
    if (!mounted || release == null || release.version == _told) return;
    _told = release.version;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Promptly ${release.version} is out.'),
        duration: const Duration(seconds: 12),
        // Gone by itself: the About page keeps the news until it is acted on.
        persist: false,
        action: SnackBarAction(
          label: 'See',
          onPressed: () => ref.read(routerProvider).go('/settings/about'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(updateCheckProvider, (_, on) {
      if (!updateChecksSupported) return;
      if (on) {
        _schedule();
      } else {
        _timer?.cancel();
        _timer = null;
      }
    });
    return widget.child;
  }
}
