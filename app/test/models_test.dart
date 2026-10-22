import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/core/engine/engine.dart';
import 'package:promptly/core/engine/records.dart';
import 'package:promptly/features/hosts/models.dart';
import 'package:promptly/features/hosts/session_labels.dart';

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

  test('a labelled host keeps its label and words, and older records keep their production mark', () {
    final h = Host(id: newRecordId(), label: 'db-1', hostname: 'db', sessionLabelId: 'staging', labelText: 'Live');
    final json = h.toJson();
    expect(json['production'], isFalse, reason: 'older apps only know the production label');
    final back = Host.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
    expect(back.sessionLabelId, 'staging');
    expect(back.labelText, 'Live');
    expect(back.copyWith(sessionLabelId: null).sessionLabelId, isNull);

    final none = Host.fromJson({'id': 'x', 'label': 'x', 'hostname': 'x'});
    expect(none.sessionLabelId, isNull);
    final old = Host.fromJson({'id': 'x', 'label': 'x', 'hostname': 'x', 'production': true, 'production_label': 'Payments'});
    expect(old.sessionLabelId, productionLabelId, reason: 'marked production before labels existed');
    expect(old.toJson()['production'], isTrue);
  });

  test('a host shows its own words, or the label\'s name, and nothing once its label is gone', () {
    const labels = [
      ...defaultSessionLabels,
      SessionLabel(id: 'stg', name: 'Staging', color: '#1F6FEB'),
    ];
    final prod = Host(id: 'a', label: 'a', hostname: 'a', sessionLabelId: productionLabelId);
    final mark = markFor(prod, labels)!;
    expect(mark.text, 'Production');
    expect(mark.warn, isTrue);
    expect(mark.color, 'red');
    final stg = markFor(prod.copyWith(sessionLabelId: 'stg', labelText: ' Blue team '), labels)!;
    expect(stg.text, 'Blue team');
    expect(stg.name, 'Staging');
    expect(markFor(prod.copyWith(sessionLabelId: 'gone'), labels), isNull);
    expect(markFor(prod.copyWith(sessionLabelId: null), labels), isNull);
    expect(parseHexColor('#1f6feb'), const Color(0xFF1F6FEB));
    expect(parseHexColor('1F6FEB'), const Color(0xFF1F6FEB));
    expect(parseHexColor('#12345'), isNull);
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

  test('one unreadable record does not empty the list', () {
    final hosts = decodeRecords(
      const [
        StoreRecord(id: 'a', json: '{"id":"a","label":"web","hostname":"web.example"}'),
        StoreRecord(id: 'b', json: '{"label":"no id","hostname":"b.example"}'),
        StoreRecord(id: 'c', json: 'not json'),
        StoreRecord(id: 'd', json: '{"id":"d","label":7}'),
      ],
      Host.fromJson,
    );
    expect(hosts.map((h) => h.id), ['a', 'b']);
    expect(hosts[1].hostname, 'b.example');
  });
}
