import 'models.dart';

/// Plain-IP DNS servers for the selected preset (also handed to the VPN interface).
List<String> dnsServersFor(AppSettings s) => switch (s.get<String>('dnsPreset')) {
      'cloudflare' => ['1.1.1.1', '1.0.0.1'],
      'google' => ['8.8.8.8', '8.8.4.4'],
      'quad9' => ['9.9.9.9', '149.112.112.112'],
      'adguard' => ['94.140.14.14', '94.140.15.15'],
      _ => [s.get<String>('dns1'), s.get<String>('dns2')],
    };

/// Custom routing lines, one per rule:  `proxy|direct|block  domain:example.com, geosite:google, ip:10.0.0.0/8`
/// Bare words are treated as `domain:`. Lines starting with # are ignored.
List<Map<String, dynamic>> parseCustomRules(String text) {
  final out = <Map<String, dynamic>>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final sp = line.indexOf(RegExp(r'\s'));
    if (sp < 0) continue;
    final action = line.substring(0, sp).toLowerCase();
    if (!{'proxy', 'direct', 'block'}.contains(action)) continue;
    final domains = <String>[], ips = <String>[];
    for (var m in line.substring(sp).split(RegExp(r'[,\s]+'))) {
      if (m.isEmpty) continue;
      if (m.startsWith('ip:')) {
        ips.add(m.substring(3));
      } else if (m.startsWith('geoip:') || RegExp(r'^\d+\.\d+\.\d+\.\d+(/\d+)?$').hasMatch(m)) {
        ips.add(m);
      } else {
        domains.add(m.contains(':') ? m : 'domain:$m');
      }
    }
    if (domains.isEmpty && ips.isEmpty) continue;
    out.add({
      'type': 'field',
      if (domains.isNotEmpty) 'domain': domains,
      if (ips.isNotEmpty) 'ip': ips,
      'outboundTag': action,
    });
  }
  return out;
}

/// Builds the Xray-core JSON for a profile.
///
/// TUN mode: Xray's own `tun` inbound consumes the file descriptor handed
/// over by the platform VPN layer (Android VpnService / iOS PacketTunnel),
/// so no separate tun2socks process is needed. A local SOCKS + HTTP inbound
/// is exposed as well so the Tools tab can test traffic through the tunnel
/// (the app itself is excluded from the VPN to avoid routing loops).
Map<String, dynamic> buildXrayConfig(
  ServerConfig c,
  AppSettings s, {
  int? sshSocksPort,
}) {
  final socksPort = s.get<int>('socksPort');
  final routing = s.get<String>('routing');
  final fragment = s.get<bool>('fragment');

  Map<String, dynamic> sniffing() => {
        'enabled': s.get<bool>('sniffing'),
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': true,
      };

  final rules = <Map<String, dynamic>>[
    {
      'type': 'field',
      'inboundTag': ['tun-in', 'socks-in', 'http-in'],
      'port': '53',
      'network': 'udp',
      'outboundTag': 'dns-out',
    },
    ...parseCustomRules(s.get<String>('customRules')),
    if (s.get<bool>('blockQuic'))
      {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'},
    if (routing != 'global') {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': 'direct'},
    if (routing == 'bypassLanAds')
      {'type': 'field', 'domain': ['geosite:category-ads-all'], 'outboundTag': 'block'},
    {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
  ];

  return {
    'log': {'loglevel': s.get<String>('logLevel')},
    'dns': {
      'servers': [...dnsServersFor(s), 'localhost'],
      'queryStrategy': s.get<bool>('ipv6') ? 'UseIP' : 'UseIPv4',
    },
    'inbounds': [
      {
        'tag': 'tun-in',
        'protocol': 'tun',
        'settings': {'name': 'xray0', 'MTU': s.get<int>('mtu')},
        'sniffing': sniffing(),
      },
      {
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'port': socksPort,
        'protocol': 'socks',
        'settings': {'udp': true, 'auth': 'noauth'},
        'sniffing': sniffing(),
      },
      {
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'port': socksPort + 1,
        'protocol': 'http',
        'sniffing': sniffing(),
      },
    ],
    'outbounds': [
      _proxyOutbound(c, s, sshSocksPort, fragment),
      {'tag': 'direct', 'protocol': 'freedom'},
      {'tag': 'block', 'protocol': 'blackhole'},
      {'tag': 'dns-out', 'protocol': 'dns'},
      if (fragment)
        {
          'tag': 'fragment',
          'protocol': 'freedom',
          'settings': {
            'fragment': {'packets': 'tlshello', 'length': '100-200', 'interval': '10-20'}
          },
        },
    ],
    'routing': {'domainStrategy': 'IPIfNonMatch', 'rules': rules},
  };
}

Map<String, dynamic> _proxyOutbound(ServerConfig c, AppSettings s, int? sshPort, bool fragment) {
  final out = <String, dynamic>{'tag': 'proxy'};
  switch (c.proto) {
    case Proto.ssh:
      // DartSSH2 exposes a local SOCKS5 port; Xray routes everything into it.
      out
        ..['protocol'] = 'socks'
        ..['settings'] = {
          'servers': [
            {'address': '127.0.0.1', 'port': sshPort ?? 1080}
          ]
        };
      return out;
    case Proto.vless:
      out
        ..['protocol'] = 'vless'
        ..['settings'] = {
          'vnext': [
            {
              'address': c.host,
              'port': c.port,
              'users': [
                {
                  'id': c.p('id'),
                  'encryption': c.p('encryption', 'none'),
                  if (c.p('flow').isNotEmpty) 'flow': c.p('flow'),
                }
              ]
            }
          ]
        };
    case Proto.vmess:
      out
        ..['protocol'] = 'vmess'
        ..['settings'] = {
          'vnext': [
            {
              'address': c.host,
              'port': c.port,
              'users': [
                {
                  'id': c.p('id'),
                  'alterId': int.tryParse(c.p('aid', '0')) ?? 0,
                  'security': c.p('method', 'auto'),
                }
              ]
            }
          ]
        };
    case Proto.trojan:
      out
        ..['protocol'] = 'trojan'
        ..['settings'] = {
          'servers': [
            {'address': c.host, 'port': c.port, 'password': c.p('id')}
          ]
        };
    case Proto.shadowsocks:
      out
        ..['protocol'] = 'shadowsocks'
        ..['settings'] = {
          'servers': [
            {
              'address': c.host,
              'port': c.port,
              'method': c.p('method', 'aes-256-gcm'),
              'password': c.p('id'),
            }
          ]
        };
  }
  out['streamSettings'] = _stream(c, s, fragment);
  if (s.get<bool>('mux') && c.p('flow').isEmpty) {
    out['mux'] = {'enabled': true, 'concurrency': 8};
  }
  return out;
}

Map<String, dynamic> _stream(ServerConfig c, AppSettings s, bool fragment) {
  final net = c.p('net', 'tcp');
  final sec = c.p('security', 'none');
  final st = <String, dynamic>{'network': net, 'security': sec};
  final host = c.p('host');
  final path = c.p('path');

  switch (net) {
    case 'ws':
      st['wsSettings'] = {
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty) 'headers': {'Host': host},
      };
    case 'grpc':
      st['grpcSettings'] = {'serviceName': c.p('serviceName')};
    case 'xhttp':
      st['xhttpSettings'] = {
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty) 'host': host,
        if (c.p('mode').isNotEmpty) 'mode': c.p('mode'),
      };
    case 'httpupgrade':
      st['httpupgradeSettings'] = {
        'path': path.isEmpty ? '/' : path,
        if (host.isNotEmpty) 'host': host,
      };
  }

  final sni = c.p('sni').isNotEmpty ? c.p('sni') : (host.isNotEmpty ? host : c.host);
  if (sec == 'tls') {
    st['tlsSettings'] = {
      'serverName': sni,
      'allowInsecure': s.get<bool>('allowInsecure'),
      if (c.p('fp').isNotEmpty) 'fingerprint': c.p('fp'),
      if (c.p('alpn').isNotEmpty) 'alpn': c.p('alpn').split(','),
    };
  } else if (sec == 'reality') {
    st['realitySettings'] = {
      'serverName': sni,
      'fingerprint': c.p('fp', 'chrome'),
      'publicKey': c.p('pbk'),
      'shortId': c.p('sid'),
      'spiderX': c.p('spx'),
    };
  }
  if (fragment && sec != 'none') {
    st['sockopt'] = {'dialerProxy': 'fragment'};
  }
  return st;
}
