import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/turn_credentials.dart';

void main() {
  test('TurnCredentials.fromJson parses the /turn/credentials response', () {
    final c = TurnCredentials.fromJson({
      'username': '1700000000:acc-1',
      'credential': 'abc123==',
      'ttl': 3600,
      'urls': [
        'turns:turn.nanb.link:443?transport=tcp',
        'turn:turn.nanb.link:3478?transport=udp',
      ],
    });
    expect(c.username, '1700000000:acc-1');
    expect(c.credential, 'abc123==');
    expect(c.ttlSeconds, 3600);
    expect(c.urls.length, 2);
    expect(c.urls.first, 'turns:turn.nanb.link:443?transport=tcp');
  });
}
