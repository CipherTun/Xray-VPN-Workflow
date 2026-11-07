import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/core/link_parser.dart';
import 'package:vpn/core/models.dart';
import 'package:vpn/core/v2tun_config.dart';

ServerConfig _p(Proto proto, {String host = '203.0.113.10', int port = 443, Map<String, String> params = const {}}) =>
    ServerConfig(id: 't', name: 't', proto: proto, host: host, port: port, params: {...params});

Map<String, dynamic> _build(ServerConfig c, {AppSettings? s, bool forPing = false, List<ServerConfig> backups = const [], List<String>? warnings}) =>
    buildV2tunConfig(c, s ?? AppSettings(), forPing: forPing, backups: backups, onWarn: warnings?.add);

void main() {
  group('V2-TUN config: protocols', () {
    test('VLESS over plain WebSocket keeps security none and the ws fields', () {
      final cfg = _build(_p(Proto.vless, port: 80, params: {
        'id': '00000000-0000-4000-8000-000000000001',
        'net': 'ws',
        'security': 'none',
        'path': '/websocket',
        'host': 'cdn.example.test',
      }));
      expect(cfg['protocol'], 'vless');
      expect(cfg['uuid'], '00000000-0000-4000-8000-000000000001');
      expect(cfg['network'], 'ws');
      expect(cfg.containsKey('tls'), isFalse);
      expect(cfg.containsKey('reality'), isFalse);
      expect((cfg['ws'] as Map)['path'], '/websocket');
      expect((cfg['ws'] as Map)['host'], 'cdn.example.test');
    });

    test('VLESS REALITY with Vision flow', () {
      final cfg = _build(_p(Proto.vless, params: {
        'id': '00000000-0000-4000-8000-000000000002',
        'security': 'reality',
        'pbk': 'PUBKEY',
        'sid': 'ab12',
        'sni': 'cover.example.test',
        'flow': 'xtls-rprx-vision',
      }));
      final r = cfg['reality'] as Map;
      expect(r['publicKey'], 'PUBKEY');
      expect(r['shortId'], 'ab12');
      expect(r['serverName'], 'cover.example.test');
      expect(r['fingerprint'], 'chrome');
      expect(cfg['flow'], 'xtls-rprx-vision');
      expect(cfg.containsKey('network'), isFalse);
    });

    test('Xray style "randomized" becomes the library name "random"', () {
      final cfg = _build(_p(Proto.trojan, params: {'id': 'pw', 'security': 'tls', 'fp': 'randomized'}));
      expect((cfg['tls'] as Map)['fingerprint'], 'random');
      expect(normalizeFingerprint('Chrome'), 'chrome');
    });

    test('Trojan, VMess and Shadowsocks use the library field names', () {
      final t = _build(_p(Proto.trojan, params: {'id': 'secret', 'security': 'tls', 'sni': 'front.example.test'}));
      expect(t['password'], 'secret');
      expect((t['tls'] as Map)['sni'], 'front.example.test');
      expect((t['tls'] as Map)['enabled'], true);

      final v = _build(_p(Proto.vmess, params: {'id': '00000000-0000-4000-8000-000000000003', 'aid': '0'}));
      expect(v['alterId'], 0);
      expect(v['method'], 'auto');

      final s = _build(_p(Proto.shadowsocks, port: 8388, params: {'method': 'aes-256-gcm', 'id': 'pw'}));
      expect(s['method'], 'aes-256-gcm');
      expect(s['password'], 'pw');
    });

    test('SOCKS and HTTP proxies carry their login', () {
      final s5 = _build(_p(Proto.socks5, port: 1080, params: {'user': 'u', 'id': 'p'}));
      expect(s5['protocol'], 'socks5');
      expect(s5['username'], 'u');
      expect(s5['password'], 'p');
      expect(_build(_p(Proto.socks4, port: 1080))['protocol'], 'socks4');
      final https = _build(_p(Proto.https, port: 443, params: {'user': 'u', 'id': 'p', 'sni': 'proxy.example.test'}));
      expect(https['protocol'], 'https');
      expect((https['tls'] as Map)['enabled'], true);
    });

    test('Hysteria 2 and Hysteria 1 skip the stream settings', () {
      final h2 = _build(_p(Proto.hysteria2, params: {'id': 'auth', 'sni': 'h.example.test', 'obfs': 'pw', 'pin': 'aabb', 'allowInsecure': '1', 'downMbps': '100'}));
      expect(h2['protocol'], 'hysteria2');
      expect(h2['password'], 'auth');
      expect((h2['tls'] as Map)['sni'], 'h.example.test');
      expect((h2['tls'] as Map)['allowInsecure'], true);
      expect((h2['hysteria'] as Map)['pinSha256'], 'aabb');
      expect((h2['hysteria'] as Map)['obfs'], 'pw');
      expect((h2['hysteria'] as Map)['downMbps'], 100);
      expect(h2.containsKey('network'), isFalse);
      expect(h2.containsKey('payload'), isFalse);

      final h1 = _build(_p(Proto.hysteria1, params: {'id': 'auth', 'upMbps': '20', 'downMbps': '80', 'alpn': 'hysteria'}));
      expect(h1['protocol'], 'hysteria');
      expect((h1['hysteria'] as Map)['upMbps'], 20);
    });
  });

  group('V2-TUN config: SSH', () {
    test('a pinned host key goes to advanced.sshHostKey, an unpinned one warns', () {
      final pinned = _build(_p(Proto.ssh, port: 22, params: {'user': 'root', 'id': 'pw', 'hostKey': 'SHA256:abc'}));
      expect((pinned['advanced'] as Map)['sshHostKey'], 'SHA256:abc');
      expect(pinned['username'], 'root');

      final warnings = <String>[];
      final open = _build(_p(Proto.ssh, port: 22, params: {'user': 'root', 'id': 'pw'}), warnings: warnings);
      expect(open.containsKey('advanced'), isFalse);
      expect(warnings.any((w) => w.contains('host key')), isTrue);
    });

    test('SSH over TLS with a payload keeps the stage and the response override', () {
      final cfg = _build(_p(Proto.ssh, port: 443, params: {
        'user': 'u',
        'id': 'p',
        'security': 'tls',
        'sni': 'bug.example.test',
        'payload': '@ssh-ws',
        'payloadStage': 'post-tls',
        'responseMap': '301=200, 3xx=200',
      }));
      expect((cfg['tls'] as Map)['sni'], 'bug.example.test');
      final pl = cfg['payload'] as Map;
      expect(pl['template'], '@ssh-ws');
      expect(pl['stage'], 'post-tls');
      expect(pl['responseMap'], {'301': 200, '3xx': 200});
    });

    test('profiles saved by the old SSH tunnel are migrated', () {
      final c = ServerConfig.fromJson({
        'id': 'a',
        'name': 'old',
        'proto': 'ssh',
        'host': 'ssh.example.test',
        'port': 22,
        'params': {'user': 'u', 'id': 'p', 'transport': 'http', 'proxyHost': 'proxy.example.test', 'proxyPort': '8080', 'responseRewrite': '302=200'},
      });
      expect(c.params.containsKey('transport'), isFalse);
      final cfg = _build(c);
      final pl = cfg['payload'] as Map;
      expect(pl['proxy'], 'proxy.example.test:8080');
      expect(pl['template'], '@connect');
      expect(pl['responseMap'], {'302': 200});
      expect(cfg['server'], 'ssh.example.test');

      final tls = ServerConfig.fromJson({
        'id': 'b', 'name': 'old', 'proto': 'ssh', 'host': 'h', 'port': 443,
        'params': {'user': 'u', 'transport': 'tls'},
      });
      expect(tls.p('security'), 'tls');
    });
  });

  group('payload spellings', () {
    test('rotate with semicolons becomes pipes, [sni=] moves to the SNI, [tls] is dropped with a warning', () {
      final m = migratePayload('GET / HTTP/1.1[crlf]Host: [rotate=a.test;b.test][crlf][sni=front.test][tls][crlf][crlf]');
      expect(m.template, contains('[rotate=a.test|b.test]'));
      expect(m.template, isNot(contains('[sni=')));
      expect(m.template, isNot(contains('[tls]')));
      expect(m.sni, 'front.test');
      expect(m.warnings, isNotEmpty);
    });

    test('the library spelling is left alone', () {
      const t = 'CONNECT [host_port] [protocol][crlf][rotate=a|b][random=x|y][crlf][crlf]';
      expect(migratePayload(t).template, t);
    });

    test('a legacy [sni=] value fills the TLS SNI when the profile has none', () {
      final cfg = _build(_p(Proto.vless, params: {'id': 'x', 'security': 'tls', 'payload': 'GET /[sni=front.test]'}));
      expect((cfg['tls'] as Map)['sni'], 'front.test');
    });

    test('response map parsing', () {
      expect(parseResponseMap('301=200, 3XX=200;404=200'), {'301': 200, '3xx': 200, '404': 200});
      expect(parseResponseMap('nonsense'), isEmpty);
    });
  });

  group('V2-TUN config: things the library cannot do are refused', () {
    test('certificate pinning, verify name and ECH', () {
      for (final k in ['pcs', 'vcn', 'ech']) {
        expect(() => _build(_p(Proto.vless, params: {'id': 'x', 'security': 'tls', k: 'value'})), throwsA(isA<V2tunConfigError>()), reason: k);
      }
    });

    test('mKCP and VLESS encryption', () {
      expect(() => _build(_p(Proto.vless, params: {'id': 'x', 'net': 'kcp'})), throwsA(isA<V2tunConfigError>()));
      expect(() => _build(_p(Proto.vless, params: {'id': 'x', 'encryption': 'mlkem768x25519plus.native.0rtt.abc'})), throwsA(isA<V2tunConfigError>()));
    });
  });

  group('V2-TUN config: shared settings', () {
    test('routing is left out of latency tests and present otherwise', () {
      final c = _p(Proto.trojan, params: {'id': 'pw', 'security': 'tls'});
      expect(_build(c, forPing: true).containsKey('routing'), isFalse);
      final r = _build(c)['routing'] as Map;
      expect(r['default'], 'proxy');
      expect(r['bypassLan'], true);
      expect(r['domainStrategy'], 'ipifnonmatch');
    });

    test('mux only for protocols that can carry it, never with a flow', () {
      final s = AppSettings()..set('mux', true)..set('muxConcurrency', 4);
      expect((_build(_p(Proto.vmess, params: {'id': '00000000-0000-4000-8000-000000000003'}), s: s)['mux'] as Map)['concurrency'], 4);
      expect(_build(_p(Proto.ssh, params: {'user': 'u'}), s: s).containsKey('mux'), isFalse);
      expect(_build(_p(Proto.vless, params: {'id': 'x', 'security': 'tls', 'flow': 'xtls-rprx-vision'}), s: s).containsKey('mux'), isFalse);
    });

    test('fragmenting only applies to TLS and REALITY', () {
      final s = AppSettings()..set('fragment', true)..set('fragLength', '50-80')..set('fragInterval', '5-9');
      final f = _build(_p(Proto.trojan, params: {'id': 'pw', 'security': 'tls'}), s: s)['fragment'] as Map;
      expect(f['length'], [50, 80]);
      expect(f['interval'], [5, 9]);
      expect(_build(_p(Proto.trojan, params: {'id': 'pw'}), s: s).containsKey('fragment'), isFalse);
    });

    test('backups keep routing, udpgw and directDns on the top level only', () {
      final s = AppSettings()..set('udpgw', '127.0.0.1:7300')..set('connectTimeout', 20);
      final main = _p(Proto.ssh, host: 'a.example.test', port: 22, params: {'user': 'u', 'id': 'p'});
      final backup = _p(Proto.vless, host: 'b.example.test', params: {'id': 'x', 'security': 'tls'});
      final cfg = _build(main, s: s, backups: [backup]);
      expect(cfg['udpgw'], '127.0.0.1:7300');
      expect(cfg.containsKey('directDns'), isTrue);
      expect(cfg['failoverTimeoutSec'], 20);
      final b = (cfg['backups'] as List).single as Map;
      expect(b['server'], 'b.example.test');
      expect(b.containsKey('routing'), isFalse);
      expect(b.containsKey('udpgw'), isFalse);
      expect(b.containsKey('directDns'), isFalse);
    });

    test('a backup the library cannot carry is skipped, the others stay', () {
      final warnings = <String>[];
      final cfg = _build(
        _p(Proto.trojan, params: {'id': 'pw'}),
        backups: [_p(Proto.vless, host: 'bad', params: {'id': 'x', 'net': 'kcp'}), _p(Proto.trojan, host: 'good', params: {'id': 'pw'})],
        warnings: warnings,
      );
      expect((cfg['backups'] as List).length, 1);
      expect(warnings.any((w) => w.contains('bad')), isTrue);
    });
  });

  group('routing', () {
    test('route lists follow the settings', () {
      expect(routeListSources(AppSettings()), isEmpty);
      final cn = AppSettings()..set('bypassCountry', 'cn');
      expect(routeListSources(cn).keys, containsAll(['geoip:cn', 'geosite:cn']));
      final ads = AppSettings()..set('routing', 'bypassLanAds');
      expect(routeListSources(ads).keys, contains(kAdsList));
      final custom = AppSettings()..set('customRules', 'direct geoip:ir\nblock geosite:netflix');
      final warnings = <String>[];
      expect(routeListSources(custom, onWarn: warnings.add).keys, contains('geoip:ir'));
      expect(warnings.any((w) => w.contains('geosite:netflix')), isTrue);
    });

    test('custom rules become library rules', () {
      final rules = parseCustomRules('# comment\ndirect domain:example.com geoip:cn ip:10.0.0.0/8 port:443\nblock protocol:bittorrent\nproxy bare.example.test\nnonsense line');
      expect(rules.length, 3);
      expect(rules[0]['action'], 'direct');
      expect(rules[0]['domain'], ['domain:example.com']);
      expect(rules[0]['ip'], ['geoip:cn', '10.0.0.0/8']);
      expect(rules[0]['port'], '443');
      expect(rules[1]['protocol'], ['bittorrent']);
      expect(rules[2]['domain'], ['domain:bare.example.test']);
    });

    test('country switches add the direct rules', () {
      final s = AppSettings()..set('bypassCountry', 'ru')..set('routing', 'bypassLanAds');
      final rules = (buildRouting(s)['rules'] as List).cast<Map>();
      expect(rules.any((r) => r['name'] == 'ads' && r['action'] == 'block'), isTrue);
      expect(rules.any((r) => r['name'] == 'country-ip' && (r['ip'] as List).contains('geoip:ru')), isTrue);
      expect(rules.any((r) => r['name'] == 'country-tld'), isTrue);
    });
  });

  group('share links', () {
    test('hysteria2 link', () {
      final c = LinkParser.parse('hysteria2://secret@example.test:8443/?sni=front.test&insecure=1&obfs=salamander&obfs-password=pw&pinSHA256=AA%3ABB#My%20HY2')!;
      expect(c.proto, Proto.hysteria2);
      expect(c.port, 8443);
      expect(c.name, 'My HY2');
      expect(c.p('id'), 'secret');
      expect(c.p('sni'), 'front.test');
      expect(c.p('allowInsecure'), '1');
      expect(c.p('obfs'), 'pw');
      expect(c.p('pin'), 'aabb');
      final back = LinkParser.parse(LinkParser.toLink(c)!)!;
      expect(back.p('id'), 'secret');
      expect(back.p('obfs'), 'pw');
      expect(back.p('pin'), 'aabb');
    });

    test('hysteria1 link and unsupported variants', () {
      final c = LinkParser.parse('hysteria://example.test:443?auth=tok&peer=front.test&upmbps=10&downmbps=50&obfs=xplus&obfsParam=pw#H1')!;
      expect(c.proto, Proto.hysteria1);
      expect(c.p('id'), 'tok');
      expect(c.p('sni'), 'front.test');
      expect(c.p('obfs'), 'pw');
      expect(LinkParser.parse('hysteria://example.test:443?auth=tok&protocol=faketcp'), isNull);
      expect(LinkParser.parse('hysteria2://secret@example.test:443/?mport=1000-2000'), isNull);
    });

    test('socks links', () {
      final c = LinkParser.parse('socks5://user:pass@example.test:1081#S')!;
      expect(c.proto, Proto.socks5);
      expect(c.p('user'), 'user');
      expect(c.p('id'), 'pass');
      expect(c.port, 1081);
      expect(LinkParser.parse('socks4a://example.test')!.proto, Proto.socks4);
    });

    test('http(s) URLs are subscriptions, not proxy links', () {
      expect(LinkParser.parse('https://sub.example.test/list'), isNull);
      expect(LinkParser.parse('http://sub.example.test/list'), isNull);
    });

    test('VLESS REALITY Vision link builds a library config', () {
      final c = LinkParser.parse('vless://11111111-1111-4111-8111-111111111111@example.test:443?type=tcp&security=reality&pbk=KEY&sid=ab12&sni=cover.test&fp=chrome&flow=xtls-rprx-vision#R')!;
      expect(c.p('flow'), 'xtls-rprx-vision');
      final cfg = _build(c);
      expect(cfg['flow'], 'xtls-rprx-vision');
      expect((cfg['reality'] as Map)['shortId'], 'ab12');
    });

    test('an unsupported flow, a Shadowsocks plugin and a Trojan link without security', () {
      expect(LinkParser.parse('vless://id@example.test:443?flow=xtls-rprx-direct'), isNull);
      expect(LinkParser.parse('ss://YWVzLTI1Ni1nY206cHc@example.test:8388?plugin=obfs-local'), isNull);
      expect(LinkParser.parse('trojan://pw@example.test:443#T')!.p('security'), 'tls');
    });
  });
}
