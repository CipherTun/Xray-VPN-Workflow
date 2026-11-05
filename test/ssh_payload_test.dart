import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/ssh_payload.dart';

void main() {
  group('SSH bootstrap response override', () {
    test('accepts an explicitly configured 302-to-200 mapping', () {
      expect(HttpResponseRewrite.targetStatus('302=200', 302), 200);
    });

    test('does not match a different received status', () {
      expect(HttpResponseRewrite.targetStatus('302=200', 301), isNull);
    });

    test('does not allow a 101 protocol-upgrade rewrite', () {
      expect(HttpResponseRewrite.targetStatus('302=101', 302), isNull);
    });

    test('rejects malformed and unsupported rules', () {
      expect(HttpResponseRewrite.targetStatus('302', 302), isNull);
      expect(HttpResponseRewrite.targetStatus('200=200', 200), isNull);
      expect(HttpResponseRewrite.targetStatus('600=200', 600), isNull);
    });
  });


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
