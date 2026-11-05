import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/ssh_payload.dart';

void main() {
  group('PayloadParser HTTP request metadata', () {
    test('detects multiple HTTP requests in one payload', () {
      final parsed = PayloadParser.parse(
        'GET /front HTTP/1.1[crlf]'
        'Host: front.example[crlf][crlf]'
        'CONNECT [host_port] [protocol][crlf]'
        'Host: [host][crlf][crlf]',
        'edge.example',
        443,
      );

      expect(parsed.methods, ['GET', 'CONNECT']);
      expect(parsed.upgradeProtocols, [null, null]);
    });

    test('records a requested WebSocket upgrade and key', () {
      final parsed = PayloadParser.parse(
        'GET /tunnel HTTP/1.1[crlf]'
        'Host: edge.example[crlf]'
        'Upgrade: websocket[crlf]'
        'Connection: Upgrade[crlf][crlf]',
        'edge.example',
        443,
      );

      expect(parsed.methods, ['GET']);
      expect(parsed.upgradeProtocols, ['websocket']);

      final key = parsed.webSocketKeys.single;
      expect(key, isNotEmpty);
      expect(base64.decode(key), hasLength(16));
    });

    test('does not mark an ordinary CONNECT as a protocol upgrade', () {
      final parsed = PayloadParser.parse(
        'CONNECT [host_port] [protocol][crlf]'
        'Host: [host][crlf][crlf]',
        'edge.example',
        443,
      );

      expect(parsed.methods, ['CONNECT']);
      expect(parsed.upgradeProtocols, [null]);
      expect(parsed.webSocketKeys, [null]);
    });
  });
}
