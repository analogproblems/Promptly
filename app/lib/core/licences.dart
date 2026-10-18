import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Add the licences Flutter does not know about to the list under About,
/// Licences: the terminal font's, and those of the C libraries the Rust
/// engine builds in. Flutter's own packages list themselves.
///
/// The texts under `assets/licences` are copied from the crates that build
/// these libraries (`openssl-src` and `libsqlite3-sys`); copy them again
/// when those move to a new major version.
void registerLicences() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const ['JetBrains Mono'], await rootBundle.loadString('assets/fonts/OFL.txt'));
    // The local database: SQLCipher, an encrypted SQLite.
    yield LicenseEntryWithLineBreaks(const ['SQLCipher'], await rootBundle.loadString('assets/licences/sqlcipher.txt'));
    // SQLCipher's encryption comes from OpenSSL, built in everywhere but
    // on Apple devices, which use the system's own crypto library.
    if (defaultTargetPlatform != TargetPlatform.iOS && defaultTargetPlatform != TargetPlatform.macOS) {
      yield LicenseEntryWithLineBreaks(const ['OpenSSL'], await rootBundle.loadString('assets/licences/openssl.txt'));
    }
  });
}
