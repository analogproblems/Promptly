import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/features/hosts/models.dart';

void main() {
  test('a host round-trips through the vault JSON format', () {
    final h = Host(
      id: newRecordId(),
      label: 'web-1',
      hostname: '10.0.0.11',
      port: 2222,
      username: 'deploy',
      auth: const HostAuth(kind: AuthKind.identity, identityId: 'key-1'),
      tags: const ['prod'],
      color: 'red',
      favourite: true,
      lastConnectedAt: DateTime.utc(2026, 10, 15, 4, 0, 0),
    );
    final json = jsonDecode(jsonEncode(h.toJson())) as Map<String, dynamic>;
    expect(json['auth'], {'kind': 'identity', 'identity_id': 'key-1'});
    expect(json['last_connected_at'], '2026-10-15T04:00:00.000Z');
    expect(json['keepalive_seconds'], 30);
    final back = Host.fromJson(json);
    expect(back.id, h.id);
    expect(back.endpoint, 'deploy@10.0.0.11:2222');
    expect(back.auth.kind, AuthKind.identity);
    expect(back.favourite, isTrue);
    expect(back.lastConnectedAt, h.lastConnectedAt);
  });

  test('ids are UUIDs and colours are stable per label', () {
    expect(newRecordId(), matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(defaultColorFor('web-1'), defaultColorFor('web-1'));
    expect(hostColorNames, contains(defaultColorFor('anything')));
  });

  test('relative time reads naturally', () {
    final now = DateTime(2026, 10, 15, 12);
    expect(relativeTime(null), '');
    expect(relativeTime(now.subtract(const Duration(seconds: 5)), now: now), 'just now');
    expect(relativeTime(now.subtract(const Duration(minutes: 7)), now: now), '7m');
    expect(relativeTime(now.subtract(const Duration(hours: 3)), now: now), '3h');
    expect(relativeTime(now.subtract(const Duration(days: 4)), now: now), '4d');
  });
}
