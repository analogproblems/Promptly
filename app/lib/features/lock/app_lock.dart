import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/engine/engine.dart';
import '../../src/rust/api/lock.dart' as rust_lock;

/// Who-is-there checks: the system's own (fingerprint, face, device PIN,
/// Windows Hello) where it has one, otherwise a passcode Promptly keeps.
abstract class Authenticator {
  /// Whether the system can check who is there on this device. Throws
  /// when it cannot tell, which is not the same as no.
  Future<bool> systemAvailable();

  /// Ask the system. True when the person passed.
  Future<bool> systemCheck(String reason);

  Future<String> hashPasscode(String passcode);
  Future<bool> verifyPasscode(String passcode, String hash);
}

class PlatformAuthenticator implements Authenticator {
  PlatformAuthenticator();

  final _auth = LocalAuthentication();

  @override
  Future<bool> systemAvailable() async {
    // Linux has no check apps can use; it gets the app passcode instead.
    if (Platform.isLinux) return false;
    return _auth.isDeviceSupported();
  }

  @override
  Future<bool> systemCheck(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> hashPasscode(String passcode) => rust_lock.passcodeHash(passcode: passcode);

  @override
  Future<bool> verifyPasscode(String passcode, String hash) =>
      rust_lock.passcodeVerify(passcode: passcode, stored: hash);
}

final authenticatorProvider = Provider<Authenticator>((_) => PlatformAuthenticator());

/// Setting keys for locking. Device-local: a lock is about this device.
abstract final class LockKeys {
  static const appLock = 'app_lock';
  static const keyUnlock = 'key_unlock';
  static const lockAfter = 'lock_after_minutes';
  static const passcode = 'app_passcode';
}

/// How locking is set up on this device.
@immutable
class LockSettings {
  const LockSettings({
    required this.appLock,
    required this.keyUnlock,
    required this.lockAfterMinutes,
    required this.passcodeHash,
  });

  /// Ask on opening Promptly, and on coming back after [lockAfterMinutes].
  final bool appLock;

  /// Ask before an SSH key is used, unless asked within [lockAfterMinutes].
  final bool keyUnlock;

  /// 0 means every time.
  final int lockAfterMinutes;

  /// The app passcode's hash, for devices without a system check.
  final String? passcodeHash;

  LockSettings copyWith({bool? appLock, bool? keyUnlock, int? lockAfterMinutes, String? passcodeHash, bool clearPasscode = false}) =>
      LockSettings(
        appLock: appLock ?? this.appLock,
        keyUnlock: keyUnlock ?? this.keyUnlock,
        lockAfterMinutes: lockAfterMinutes ?? this.lockAfterMinutes,
        passcodeHash: clearPasscode ? null : passcodeHash ?? this.passcodeHash,
      );
}

/// A request for the app passcode, shown by [LockGate].
class PasscodeRequest {
  PasscodeRequest(this.reason);
  final String reason;
  final Completer<bool> done = Completer<bool>();
}

@immutable
class LockState {
  const LockState({required this.settings, required this.locked, this.passcodeRequest, this.systemAvailable});

  final LockSettings settings;

  /// The whole app is behind the lock screen.
  final bool locked;

  /// Waiting for the app passcode.
  final PasscodeRequest? passcodeRequest;

  /// Null until known, and when asking failed.
  final bool? systemAvailable;

  LockState copyWith({
    LockSettings? settings,
    bool? locked,
    PasscodeRequest? passcodeRequest,
    bool clearRequest = false,
    bool? systemAvailable,
  }) =>
      LockState(
        settings: settings ?? this.settings,
        locked: locked ?? this.locked,
        passcodeRequest: clearRequest ? null : passcodeRequest ?? this.passcodeRequest,
        systemAvailable: systemAvailable ?? this.systemAvailable,
      );
}

class AppLock extends Notifier<LockState> {
  DateTime? _lastPassed;
  DateTime? _wentAway;
  bool _checking = false;

  /// Time spent away while a check was on screen. The check's own system
  /// screen (a device PIN, say) can send the app away, so this is settled
  /// by how the check ends: passing clears it, anything else applies it.
  Duration? _awayDuringCheck;

  @override
  LockState build() {
    final engine = ref.read(engineProvider);
    final settings = LockSettings(
      appLock: _readBool(engine, LockKeys.appLock, false),
      keyUnlock: _readBool(engine, LockKeys.keyUnlock, true),
      lockAfterMinutes: _readInt(engine, LockKeys.lockAfter, 5),
      passcodeHash: _readString(engine, LockKeys.passcode),
    );
    unawaited(_probe());
    return LockState(settings: settings, locked: settings.appLock);
  }

  Future<void> _probe() async {
    bool? available;
    try {
      available = await ref.read(authenticatorProvider).systemAvailable();
    } catch (_) {
      // Could not tell: left unknown, so nothing takes it for "no check".
    }
    state = LockState(
      settings: state.settings,
      locked: state.locked,
      passcodeRequest: state.passcodeRequest,
      systemAvailable: available,
    );
  }

  bool get _recent {
    final last = _lastPassed;
    final minutes = state.settings.lockAfterMinutes;
    if (last == null || minutes <= 0) return false;
    return DateTime.now().difference(last) < Duration(minutes: minutes);
  }

  /// Check who is there now. On a device with nothing to check with (no
  /// system check, no passcode) the answer is [whenNothingToAsk]: yes where
  /// there is nothing to protect with, such as a key on Linux with no
  /// passcode, but no for the app lock, which stays shut until a check can
  /// pass. When Promptly could not even tell whether there is a system
  /// check, the answer is no.
  Future<bool> check(String reason, {bool whenNothingToAsk = false}) async {
    if (_checking) return false;
    _checking = true;
    var passed = false;
    try {
      // Asked again each time it is not yet known to work: the first look
      // may still be running or have failed, or a screen lock was added.
      if (state.systemAvailable != true) await _probe();
      if (state.systemAvailable == true) {
        passed = await ref.read(authenticatorProvider).systemCheck(reason);
      } else if (state.settings.passcodeHash != null) {
        final request = PasscodeRequest(reason);
        state = state.copyWith(passcodeRequest: request);
        passed = await request.done.future;
        state = state.copyWith(clearRequest: true);
      } else {
        passed = state.systemAvailable == false && whenNothingToAsk;
      }
      if (passed) _lastPassed = DateTime.now();
      return passed;
    } finally {
      _checking = false;
      final away = _awayDuringCheck;
      _awayDuringCheck = null;
      if (passed) {
        // Whoever is there just proved it, so time away so far doesn't count.
        _wentAway = null;
      } else if (away != null) {
        _lockIfAwayFor(away);
      }
    }
  }

  /// For [LockGate]: check a typed passcode against the stored one.
  Future<bool> submitPasscode(String passcode) async {
    final request = state.passcodeRequest;
    final hash = state.settings.passcodeHash;
    if (request == null || hash == null) return false;
    final ok = await ref.read(authenticatorProvider).verifyPasscode(passcode, hash);
    if (ok && !request.done.isCompleted) request.done.complete(true);
    return ok;
  }

  void cancelPasscode() {
    final request = state.passcodeRequest;
    if (request != null && !request.done.isCompleted) request.done.complete(false);
  }

  /// Before an SSH key is used: ask, unless that is turned off or the
  /// person passed a check within the lock time.
  Future<bool> unlockKeys() async {
    if (!state.settings.keyUnlock || _recent) return true;
    return check('Unlock your SSH key', whenNothingToAsk: true);
  }

  /// Open the app from the lock screen.
  Future<bool> unlockApp() async {
    final ok = await check('Unlock Promptly');
    if (ok) state = state.copyWith(locked: false);
    return ok;
  }

  void lockNow() {
    if (state.settings.appLock) {
      _lastPassed = null;
      state = state.copyWith(locked: true);
    }
  }

  /// The app went to the background, or its window was hidden.
  void wentAway() {
    _wentAway ??= DateTime.now();
  }

  /// The app is in front again: lock if it was away for the lock time.
  void cameBack() {
    final away = _wentAway;
    _wentAway = null;
    if (away == null) return;
    final gone = DateTime.now().difference(away);
    if (_checking) {
      final before = _awayDuringCheck;
      _awayDuringCheck = before == null ? gone : before + gone;
    } else {
      _lockIfAwayFor(gone);
    }
  }

  void _lockIfAwayFor(Duration gone) {
    if (!state.settings.appLock || state.locked) return;
    final minutes = state.settings.lockAfterMinutes;
    if (minutes <= 0 || gone >= Duration(minutes: minutes)) lockNow();
  }

  // ---- Settings -------------------------------------------------------
  //
  // Anything that makes the locks weaker needs a fresh check first, so
  // someone holding an unlocked device cannot just switch them off. Each
  // returns whether the change was made.

  /// Turning it on proves the check works before relying on it.
  Future<bool> setAppLock(bool on) async {
    if (on == state.settings.appLock) return true;
    if (!await check(on ? 'Turn on the app lock' : 'Turn off the app lock', whenNothingToAsk: !on)) return false;
    _save(state.settings.copyWith(appLock: on));
    return true;
  }

  Future<bool> setKeyUnlock(bool on) async {
    if (on == state.settings.keyUnlock) return true;
    if (!on && !await check('Turn off unlocking SSH keys', whenNothingToAsk: true)) return false;
    _save(state.settings.copyWith(keyUnlock: on));
    return true;
  }

  /// A longer time (0, every time, is the shortest) asks less often.
  Future<bool> setLockAfter(int minutes) async {
    if (minutes == state.settings.lockAfterMinutes) return true;
    if (minutes > state.settings.lockAfterMinutes && !await check('Ask less often', whenNothingToAsk: true)) {
      return false;
    }
    _save(state.settings.copyWith(lockAfterMinutes: minutes));
    return true;
  }

  Future<void> setPasscode(String passcode) async {
    final hash = await ref.read(authenticatorProvider).hashPasscode(passcode);
    _save(state.settings.copyWith(passcodeHash: hash));
  }

  /// Also turns the app lock off, which has nothing else to check with.
  Future<bool> clearPasscode() async {
    if (!await check('Remove the app passcode', whenNothingToAsk: true)) return false;
    _save(state.settings.copyWith(clearPasscode: true, appLock: false));
    return true;
  }

  void _save(LockSettings s) {
    state = state.copyWith(settings: s);
    final engine = ref.read(engineProvider);
    try {
      engine.settingSet(LockKeys.appLock, jsonEncode(s.appLock));
      engine.settingSet(LockKeys.keyUnlock, jsonEncode(s.keyUnlock));
      engine.settingSet(LockKeys.lockAfter, jsonEncode(s.lockAfterMinutes));
      engine.settingSet(LockKeys.passcode, jsonEncode(s.passcodeHash));
    } catch (_) {
      // Still in effect for this run.
    }
  }
}

final appLockProvider = NotifierProvider<AppLock, LockState>(AppLock.new);

Object? _read(Engine engine, String key) {
  try {
    final raw = engine.settingGet(key);
    return raw == null ? null : jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

bool _readBool(Engine engine, String key, bool fallback) {
  final v = _read(engine, key);
  return v is bool ? v : fallback;
}

int _readInt(Engine engine, String key, int fallback) {
  final v = _read(engine, key);
  return v is int ? v : fallback;
}

String? _readString(Engine engine, String key) {
  final v = _read(engine, key);
  return v is String ? v : null;
}
