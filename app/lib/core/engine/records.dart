import 'dart:convert';

import 'engine.dart';

/// Decode a collection's records, leaving out any that cannot be read, so
/// one damaged record never empties a whole list. A record whose JSON has
/// no id takes the one the store keeps it under.
List<T> decodeRecords<T>(Iterable<StoreRecord> records, T Function(Map<String, dynamic>) fromJson) {
  final out = <T>[];
  for (final r in records) {
    try {
      final json = jsonDecode(r.json) as Map<String, dynamic>;
      json['id'] ??= r.id;
      out.add(fromJson(json));
    } catch (_) {
      // Unreadable: skipped, and the rest still show.
    }
  }
  return out;
}
