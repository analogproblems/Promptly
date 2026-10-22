import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router.dart';
import '../onboarding/onboarding.dart';
import 'updates.dart';

/// With the setting on, looks for a new version a little after launch and
/// once a day after that, and says so once per version found. With the
/// setting never touched, offers once to turn it on.
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

  static const _offerAfter = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    if (!updateChecksSupported) return;
    if (ref.read(updateCheckProvider)) {
      _schedule();
    } else if (!ref.read(updateCheckProvider.notifier).chosen && ref.read(onboardingDoneProvider)) {
      // Not on the first run, which has the welcome tour to get through.
      _timer = Timer(_offerAfter, _offer);
    }
  }

  /// Ask once whether to check daily. Asking counts as the answer "no"
  /// until Turn on is pressed, so it never comes back.
  void _offer() {
    if (!mounted || ref.read(updateCheckProvider.notifier).chosen) return;
    ref.read(updateCheckProvider.notifier).set(false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        key: const Key('update-check-offer'),
        content: const Text('Check for new versions once a day? Promptly only asks GitHub. You can change this in Settings.'),
        duration: const Duration(seconds: 20),
        persist: false,
        action: SnackBarAction(
          label: 'Turn on',
          onPressed: () => ref.read(updateCheckProvider.notifier).set(true),
        ),
      ),
    );
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
          label: release.assetFor(installKind) != null ? 'Update' : 'See',
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
