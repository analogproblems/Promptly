import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _name = 'promptly-device-key';

// The legacy login keychain on macOS: the data protection keychain needs a
// provisioning profile, which an unsigned build does not have.
const _storage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

/// The key that encrypts saved passwords, private keys and the vault key on
/// disk. It is made once per device and kept in the platform's secure storage
/// (Keychain, Keystore, Credential Manager or the Secret Service).
///
/// Returns null when that storage is unavailable, as on a Linux desktop with
/// no Secret Service; secrets are then plain files, protected only by file
/// permissions.
Future<Uint8List?> loadDeviceKey() async {
  try {
    final existing = await _storage.read(key: _name);
    if (existing != null) {
      final key = base64Decode(existing);
      return key.length == 32 ? key : null;
    }
    final rnd = Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    final encoded = base64Encode(key);
    await _storage.write(key: _name, value: encoded);
    // Some stores report success without keeping the value; a key that is
    // not there next launch would lock every secret away.
    if (await _storage.read(key: _name) != encoded) return null;
    return key;
  } catch (_) {
    return null;
  }
}
