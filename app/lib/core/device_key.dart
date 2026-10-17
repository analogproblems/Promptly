import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the device key is kept: one value, read and written whole.
abstract class KeySlot {
  Future<String?> read();
  Future<void> write(String value);
}

/// The platform's secure storage: Keychain, Keystore, Credential Manager or
/// the Secret Service.
class SecureStorageSlot implements KeySlot {
  const SecureStorageSlot();

  static const _name = 'promptly-device-key';

  // The legacy login keychain on macOS: the data protection keychain needs a
  // provisioning profile, which an unsigned build does not have.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> read() => _storage.read(key: _name);

  @override
  Future<void> write(String value) => _storage.write(key: _name, value: value);
}

/// What became of the device key at startup.
sealed class DeviceKey {
  const DeviceKey();
}

/// The key, made now or read back.
class DeviceKeyReady extends DeviceKey {
  const DeviceKeyReady(this.bytes);
  final Uint8List bytes;
}

/// No secure storage to keep a key in: a Linux desktop with no keyring.
/// Secrets stay owner-only plain files.
class DeviceKeyNoStorage extends DeviceKey {
  const DeviceKeyNoStorage();
}

/// The secure storage is there but would not give up the key: denied,
/// locked or damaged. Secrets are neither read nor written.
class DeviceKeyRefused extends DeviceKey {
  const DeviceKeyRefused();
}

/// The key that encrypts saved passwords, private keys and the vault key on
/// disk, made once per device and kept in [slot].
///
/// Only on Linux does a failure mean there is no secure storage at all;
/// anywhere else, and for a stored key that is not a key, it means the
/// storage refused, and a new key must not be made over the old one.
Future<DeviceKey> loadDeviceKey({KeySlot slot = const SecureStorageSlot(), bool? linux}) async {
  final noStorage = (linux ?? Platform.isLinux) ? const DeviceKeyNoStorage() : const DeviceKeyRefused();
  String? existing;
  try {
    existing = await slot.read();
  } catch (_) {
    return noStorage;
  }
  if (existing != null) {
    try {
      final key = base64Decode(existing);
      if (key.length == 32) return DeviceKeyReady(key);
    } on FormatException {
      // Falls through: a damaged key.
    }
    return const DeviceKeyRefused();
  }
  final rnd = Random.secure();
  final key = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
  final encoded = base64Encode(key);
  try {
    await slot.write(encoded);
    // Some stores report success without keeping the value; a key that is
    // not there next launch would lock every secret away.
    if (await slot.read() != encoded) return noStorage;
  } catch (_) {
    return noStorage;
  }
  return DeviceKeyReady(key);
}
