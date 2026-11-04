import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/core/models.dart';
import 'package:vpn/core/xray_config.dart';

ServerConfig _vless(String id) => ServerConfig(
      id: id,
      name: id,
      proto: Proto.vless,
      host: '203.0.113.20',
      port: 443,
      params: {
        'id': '00000000-0000-4000-8000-000000000003',
        'net': 'tcp',
        'security': 'tls',
      },
    );

List<Map<String, dynamic>> _inbounds(Map<String, dynamic> cfg) => (cfg['inbounds'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _inbound(Map<String, dynamic> cfg, String tag) => _inbounds(cfg).firstWhere((i) => i['tag'] == tag);

void main() {
  group('local exposure of the tunnel', () {
    test('LAN inbounds stay closed without a login', () {
      final s = AppSettings()..set('allowLan', true);
      final warnings = <String>[];
      final cfg = buildXrayConfig(_vless('a'), s, onWarn: warnings.add);
      expect(_inbounds(cfg).any((i) => i['tag'] == 'lan-socks' || i['tag'] == 'lan-http'), isFalse);
      expect(warnings, isNotEmpty);
    });

    test('LAN inbounds always require the login', () {
      final s = AppSettings()
        ..set('allowLan', true)
        ..set('localUser', 'user')
        ..set('localPass', 'secret');
      final cfg = buildXrayConfig(_vless('a'), s);
      final socks = _inbound(cfg, 'lan-socks')['settings'] as Map;
      expect(socks['auth'], 'password');
      expect((socks['accounts'] as List).first['user'], 'user');
      expect(((_inbound(cfg, 'lan-http')['settings'] as Map)['accounts'] as List), isNotEmpty);
    });

    test('loopback inbounds use the session login when one is given', () {
      final cfg = buildXrayConfig(_vless('a'), AppSettings(), localAuth: (user: 'u', pass: 'p'));
      final socks = _inbound(cfg, 'socks-in')['settings'] as Map;
      expect(socks['auth'], 'password');
      expect((socks['accounts'] as List).first['pass'], 'p');
      final http = _inbound(cfg, 'http-in')['settings'] as Map;
      expect((http['accounts'] as List).first['user'], 'u');
    });

    test('leastLoad balancing gets a burst observatory', () {
      final s = AppSettings()..set('failoverMode', 'leastLoad');
      final cfg = buildXrayConfig(_vless('a'), s, pool: [_vless('b')]);
      expect(cfg.containsKey('burstObservatory'), isTrue);
    });

    test('an invalid JSON override is reported, not silently dropped', () {
      final s = AppSettings()..set('xrayJson', '{not json');
      final warnings = <String>[];
      buildXrayConfig(_vless('a'), s, onWarn: warnings.add);
      expect(warnings, isNotEmpty);
    });
  });
}
