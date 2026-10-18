import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/device_key.dart';

class FakeSlot implements KeySlot {
  FakeSlot({this.value, this.readFails = false, this.writeFails = false, this.dropsWrites = false});

  String? value;
  bool readFails;
  bool writeFails;
  bool dropsWrites;
  int writes = 0;

  @override
  Future<String?> read() async {
    if (readFails) throw Exception('denied');
    return value;
  }

  @override
  Future<void> write(String v) async {
    writes++;
    if (writeFails) throw Exception('locked');
    if (!dropsWrites) value = v;
  }
}

void main() {
  test('a new device makes a key once and reads the same one back', () async {
    final slot = FakeSlot();
    final first = await loadDeviceKey(slot: slot, linux: false);
    expect(first, isA<DeviceKeyReady>());
    final again = await loadDeviceKey(slot: slot, linux: false);
    expect((again as DeviceKeyReady).bytes, (first as DeviceKeyReady).bytes);
    expect(slot.writes, 1);
  });

  test('outside Linux, storage that fails is refused, never plain', () async {
    expect(await loadDeviceKey(slot: FakeSlot(readFails: true), linux: false), isA<DeviceKeyRefused>());
    expect(await loadDeviceKey(slot: FakeSlot(writeFails: true), linux: false), isA<DeviceKeyRefused>());
    expect(await loadDeviceKey(slot: FakeSlot(dropsWrites: true), linux: false), isA<DeviceKeyRefused>());
  });

  test('on Linux, a missing keyring means plain files', () async {
    expect(await loadDeviceKey(slot: FakeSlot(readFails: true), linux: true), isA<DeviceKeyNoStorage>());
    expect(await loadDeviceKey(slot: FakeSlot(writeFails: true), linux: true), isA<DeviceKeyNoStorage>());
  });

  test('a damaged stored key is refused and never replaced', () async {
    for (final bad in ['not base64!', base64Encode([1, 2, 3])]) {
      for (final linux in [true, false]) {
        final slot = FakeSlot(value: bad);
        expect(await loadDeviceKey(slot: slot, linux: linux), isA<DeviceKeyRefused>());
        expect(slot.writes, 0);
        expect(slot.value, bad);
      }
    }
  });

  test('no key next to a database encrypted with one is refused, not replaced', () async {
    final dir = Directory.systemTemp.createTempSync('promptly-key');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = File('${dir.path}/promptly.db');
    final slot = FakeSlot();

    // A plain database from a keyring-less start: a key can be made now.
    db.writeAsBytesSync([...utf8.encode('SQLite format 3'), 0, 1, 2, 3]);
    expect(await loadDeviceKey(slot: slot, linux: true, dataDir: dir.path), isA<DeviceKeyReady>());

    // An encrypted one, and the keyring comes back empty.
    db.writeAsBytesSync(List.generate(64, (i) => i * 7));
    for (final linux in [true, false]) {
      final empty = FakeSlot();
      expect(await loadDeviceKey(slot: empty, linux: linux, dataDir: dir.path), isA<DeviceKeyRefused>());
      expect(empty.writes, 0);
    }
    expect(
      await loadDeviceKey(slot: FakeSlot(readFails: true), linux: true, dataDir: dir.path),
      isA<DeviceKeyRefused>(),
      reason: 'a keyring gone on Linux does not open it plain',
    );
  });
}
