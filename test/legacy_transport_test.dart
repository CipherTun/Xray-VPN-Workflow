import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/core/models.dart';
import 'package:vpn/core/xray_config.dart';

void main() {
  group('legacy Xray transport profiles', () {
    Map<String, dynamic> outbound(ServerConfig profile) {
      final config = buildXrayConfig(profile, AppSettings());
      return (config['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['tag'] == 'proxy');
    }

    test('VLESS WS port 80 keeps security none and WS metadata', () {
      final item = outbound(ServerConfig(
        id: 'vless-ws-80',
        name: 'Legacy VLESS WS',
        proto: Proto.vless,
        host: '203.0.113.10',
        port: 80,
        params: {
          'id': '00000000-0000-4000-8000-000000000001',
          'net': 'ws',
          'security': 'none',
          'path': '/websocket',
          'host': 'cdn.example.test',
          'encryption': 'none',
        },
      ));

      final stream = item['streamSettings'] as Map<String, dynamic>;
      expect(item['protocol'], 'vless');
      expect(stream['network'], 'ws');
      expect(stream['security'], 'none');
      expect((stream['wsSettings'] as Map)['path'], '/websocket');
      expect((stream['wsSettings'] as Map)['headers']['Host'], 'cdn.example.test');
    });

    test('Trojan WS without TLS preserves plaintext transport selection', () {
      final item = outbound(ServerConfig(
        id: 'trojan-ws-80',
        name: 'Legacy Trojan WS',
        proto: Proto.trojan,
        host: '203.0.113.11',
        port: 80,
        params: {
          'id': 'test-password',
          'net': 'ws',
          'security': 'none',
          'path': '/trojan',
          'host': 'front.example.test',
        },
      ));
      final stream = item['streamSettings'] as Map<String, dynamic>;
      expect(item['protocol'], 'trojan');
      expect(stream['security'], 'none');
      expect((stream['wsSettings'] as Map)['path'], '/trojan');
      expect((stream['wsSettings'] as Map)['headers']['Host'], 'front.example.test');
    });

    test('VMess WS keeps the selected security method', () {
      final item = outbound(ServerConfig(
        id: 'vmess-ws',
        name: 'VMess WS',
        proto: Proto.vmess,
        host: 'vmess.example.test',
        port: 80,
        params: {
          'id': '00000000-0000-4000-8000-000000000002',
          'aid': '0',
          'method': 'auto',
          'net': 'ws',
          'security': 'none',
          'path': '/vmess',
        },
      ));
      final stream = item['streamSettings'] as Map<String, dynamic>;
      expect(item['protocol'], 'vmess');
      expect(stream['security'], 'none');
      expect((stream['wsSettings'] as Map)['path'], '/vmess');
    });

    test('Shadowsocks outbound generation remains unchanged', () {
      final item = outbound(ServerConfig(
        id: 'ss',
        name: 'Shadowsocks',
        proto: Proto.shadowsocks,
        host: 'ss.example.test',
        port: 8388,
        params: {'method': 'aes-256-gcm', 'id': 'password'},
      ));
      expect(item['protocol'], 'shadowsocks');
      expect((item['settings'] as Map)['servers'][0]['method'], 'aes-256-gcm');
      expect((item['settings'] as Map)['servers'][0]['password'], 'password');
    });
  });
}
