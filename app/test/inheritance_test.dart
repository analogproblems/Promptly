import 'package:flutter_test/flutter_test.dart';
import 'package:promptly/features/hosts/inheritance.dart';
import 'package:promptly/features/hosts/models.dart';

void main() {
  final team = Group(id: 'team', label: 'Team', defaults: const {'username': 'ops', 'jump_host_id': 'bastion'});
  final prod = Group(
    id: 'prod',
    label: 'Production',
    parentId: 'team',
    defaults: const {'identity_id': 'k1', 'port': 2222, 'username': '  '},
  );

  test('a host takes what its group, and the group above it, fill in', () {
    final host = Host(id: 'h1', label: 'db', hostname: 'db.example', groupId: 'prod');
    final i = Inherited(host, [team, prod]);
    expect(i.username, 'ops', reason: "a blank group user falls through to the parent's");
    expect(i.port, 2222, reason: 'a host left on 22 takes the group port');
    expect(i.jumpHostId, 'bastion');
    expect(i.auth.kind, AuthKind.identity);
    expect(i.auth.identityId, 'k1');
    expect(i.endpoint, 'ops@db.example:2222');
  });

  test("a host's own settings win, and None keeps no login", () {
    final host = Host(
      id: 'h1',
      label: 'db',
      hostname: 'db.example',
      port: 2200,
      username: 'postgres',
      jumpHostId: 'other',
      auth: const HostAuth(kind: AuthKind.none),
      groupId: 'prod',
    );
    final i = Inherited(host, [team, prod]);
    expect(i.username, 'postgres');
    expect(i.port, 2200);
    expect(i.jumpHostId, 'other');
    expect(i.auth.kind, AuthKind.none);
  });

  test('groups that contain each other do not loop', () {
    final a = Group(id: 'a', label: 'A', parentId: 'b');
    final b = Group(id: 'b', label: 'B', parentId: 'a');
    final host = Host(id: 'h1', label: 'x', hostname: 'x', groupId: 'a');
    expect(Inherited(host, [a, b]).groupUser, isNull);
  });

  test('search matches labels, addresses, users, tags and notes', () {
    final host = Host(
      id: 'h1',
      label: 'web-1',
      hostname: '10.0.0.11',
      username: 'deploy',
      tags: const ['EU-West'],
      notes: 'Behind the office firewall',
    );
    for (final q in ['web', '10.0', 'deploy', 'eu-w', 'firewall']) {
      expect(hostMatches(host, q), isTrue, reason: q);
    }
    expect(hostMatches(host, 'nas'), isFalse);
  });

  test('tags are read from a comma list without blanks or repeats', () {
    expect(parseTags(' web, eu-west ,, Web , db '), ['web', 'eu-west', 'db']);
    expect(parseTags(''), isEmpty);
  });
}
