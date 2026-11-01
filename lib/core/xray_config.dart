import 'dart:convert';

import 'models.dart';

/// Plain-IP DNS servers for the selected preset (also handed to the VPN interface).
List<String> dnsServersFor(AppSettings s) => switch (s.get<String>('dnsPreset')) {
      'cloudflare' => ['1.1.1.1', '1.0.0.1'],
      'google' => ['8.8.8.8', '8.8.4.4'],
      'quad9' => ['9.9.9.9', '149.112.112.112'],
      'adguard' => ['94.140.14.14', '94.140.15.15'],
      _ => [s.get<String>('dns1'), s.get<String>('dns2')],
    };

/// DNS servers as Xray understands them. With DoH on, presets use their https:// endpoints
/// (queried through the proxy), a custom preset can list anything Xray accepts
/// (`https://…`, `tcp://…`, `quic+local://…`, plain IPs), comma separated.
List<String> xrayDnsServers(AppSettings s) {
  final preset = s.get<String>('dnsPreset');
  if (preset == 'custom') {
    final custom = s.get<String>('dnsRemote').split(RegExp(r'[,\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return custom.isNotEmpty ? custom : dnsServersFor(s);
  }
  if (s.get<bool>('dnsDoh')) {
    return switch (preset) {
      'google' => ['https://dns.google/dns-query'],
      'quad9' => ['https://dns.quad9.net/dns-query'],
      'adguard' => ['https://dns.adguard-dns.com/dns-query'],
      _ => ['https://cloudflare-dns.com/dns-query'],
    };
  }
  return dnsServersFor(s);
}

/// Custom routing lines, one per rule:  `proxy|direct|block  domain:example.com, geosite:google, ip:10.0.0.0/8`
/// Extra selectors: `port:443`, `port:1000-2000`, `protocol:bittorrent`.
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
    final domains = <String>[], ips = <String>[], protocols = <String>[];
    String? port;
    for (var m in line.substring(sp).split(RegExp(r'[,\s]+'))) {
      if (m.isEmpty) continue;
      if (m.startsWith('ip:')) {
        ips.add(m.substring(3));
      } else if (m.startsWith('port:')) {
        port = m.substring(5);
      } else if (m.startsWith('protocol:')) {
        protocols.add(m.substring(9));
      } else if (m.startsWith('geoip:') || RegExp(r'^\d+\.\d+\.\d+\.\d+(/\d+)?$').hasMatch(m)) {
        ips.add(m);
      } else {
        domains.add(m.contains(':') ? m : 'domain:$m');
      }
    }
    if (domains.isEmpty && ips.isEmpty && protocols.isEmpty && port == null) continue;
    out.add({
      'type': 'field',
      if (domains.isNotEmpty) 'domain': domains,
      if (ips.isNotEmpty) 'ip': ips,
      if (port != null) 'port': port,
      if (protocols.isNotEmpty) 'protocol': protocols,
      'outboundTag': action,
    });
  }
  return out;
}

/// Parses `domain 1.2.3.4` lines into an Xray `dns.hosts` map.
Map<String, dynamic> parseDnsHosts(String text) {
  final hosts = <String, dynamic>{};
  for (final raw in text.split('\n')) {
    final line = raw.split('#').first.trim();
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[0].isNotEmpty) hosts[parts[0]] = parts[1];
  }
  return hosts;
}

Map<String, dynamic> _deepMerge(Map<String, dynamic> base, Map<String, dynamic> over) {
  final out = Map<String, dynamic>.from(base);
  over.forEach((k, v) {
    final cur = out[k];
    out[k] = (cur is Map<String, dynamic> && v is Map<String, dynamic>) ? _deepMerge(cur, v) : v;
  });
  return out;
}

/// Builds the Xray-core JSON for a profile.
///
/// TUN mode: Xray's own `tun` inbound consumes the file descriptor handed
/// over by the platform VPN layer (Android VpnService / iOS PacketTunnel),
/// so no separate tun2socks process is needed. A local SOCKS + HTTP inbound
/// is exposed as well so the Tools tab can test traffic through the tunnel
/// (the app itself is excluded from the VPN to avoid routing loops).
///
/// [pool] adds failover/load-balancing servers (Xray balancer + observatory).
/// [chain] sends the connection through another server first (double hop).
Map<String, dynamic> buildXrayConfig(
  ServerConfig c,
  AppSettings s, {
  int? sshSocksPort,
  List<ServerConfig> pool = const [],
  ServerConfig? chain,
}) {
  final socksPort = s.get<int>('socksPort');
  final routing = s.get<String>('routing');
  final fragment = s.get<bool>('fragment');
  final fakeDns = s.get<bool>('fakeDns');
  final balance = pool.isNotEmpty && s.get<String>('failoverMode') != 'off' && c.proto != Proto.ssh;
  final useChain = chain != null && chain.proto != Proto.ssh && c.proto != Proto.ssh && !fragment && !balance;
  final proxyTag = balance ? 'proxy-1' : 'proxy';

  Map<String, dynamic> sniffing() {
    final over = s.get<String>('sniffOverride').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (fakeDns && !over.contains('fakedns')) over.add('fakedns');
    return {
      'enabled': s.get<bool>('sniffing') || fakeDns,
      'destOverride': over,
      'routeOnly': s.get<bool>('routeOnly') && !fakeDns,
    };
  }

  Map<String, dynamic> target() => balance ? {'balancerTag': 'proxy-balance'} : {'outboundTag': 'proxy'};
  final cc = s.get<String>('bypassCountry');

  final rules = <Map<String, dynamic>>[
    {
      'type': 'field',
      'inboundTag': ['tun-in', 'socks-in', 'http-in'],
      'port': '53',
      'network': 'udp',
      'outboundTag': 'dns-out',
    },
    ...parseCustomRules(s.get<String>('customRules')),
    if (s.get<bool>('blockQuic')) {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'},
    if (s.get<bool>('blockBittorrent')) {'type': 'field', 'protocol': ['bittorrent'], 'outboundTag': 'block'},
    if (routing != 'global') {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': 'direct'},
    if (routing == 'bypassLanAds') {'type': 'field', 'domain': ['geosite:category-ads-all'], 'outboundTag': 'block'},
    if (cc == 'cn')
      {'type': 'field', 'domain': ['geosite:cn'], 'outboundTag': 'direct'},
    if (cc != 'none')
      {'type': 'field', 'ip': ['geoip:$cc'], 'outboundTag': 'direct'},
    if (cc == 'ir' || cc == 'ru')
      {'type': 'field', 'domain': ['domain:$cc'], 'outboundTag': 'direct'},
    {'type': 'field', 'network': 'tcp,udp', ...target()},
  ];
  if (balance) {
    // Custom `proxy` rules should use the balancer too.
    for (final r in rules) {
      if (r['outboundTag'] == 'proxy') {
        r.remove('outboundTag');
        r['balancerTag'] = 'proxy-balance';
      }
    }
  }

  final dnsServers = <dynamic>[if (fakeDns) 'fakedns', ...xrayDnsServers(s), 'localhost'];
  final hosts = parseDnsHosts(s.get<String>('dnsHosts'));
  final dnsStrat = s.get<String>('dnsStrategy');
  final strategy = dnsStrat == 'auto' ? (s.get<bool>('ipv6') ? 'UseIP' : 'UseIPv4') : dnsStrat;

  final lanListen = s.get<bool>('allowLan');
  final user = s.get<String>('localUser'), pass = s.get<String>('localPass');
  final lanAuth = lanListen && user.isNotEmpty && pass.isNotEmpty;

  final outbounds = <Map<String, dynamic>>[
    _proxyOutbound(c, s, sshSocksPort, fragment, proxyTag, useChain ? 'chain' : null),
    if (balance)
      for (var i = 0; i < pool.length; i++) _proxyOutbound(pool[i], s, null, fragment, 'proxy-${i + 2}', null),
    if (useChain) _proxyOutbound(chain!, s, null, false, 'chain', null),
    {'tag': 'direct', 'protocol': 'freedom'},
    {'tag': 'block', 'protocol': 'blackhole'},
    {'tag': 'dns-out', 'protocol': 'dns'},
    if (fragment)
      {
        'tag': 'fragment',
        'protocol': 'freedom',
        'settings': {
          'fragment': {
            'packets': s.get<String>('fragPackets'),
            'length': s.get<String>('fragLength'),
            'interval': s.get<String>('fragInterval'),
          }
        },
      },
  ];

  final cfg = <String, dynamic>{
    'log': {'loglevel': s.get<String>('logLevel')},
    'dns': {
      'servers': dnsServers,
      if (hosts.isNotEmpty) 'hosts': hosts,
      'queryStrategy': strategy,
      'disableCache': !s.get<bool>('dnsCache'),
    },
    if (fakeDns)
      'fakedns': [
        {'ipPool': '198.18.0.0/15', 'poolSize': 65535}
      ],
    'policy': {
      'levels': {
        '0': {'handshake': 4, 'connIdle': s.get<int>('connIdle'), 'uplinkOnly': 2, 'downlinkOnly': 5}
      }
    },
    'inbounds': [
      {
        'tag': 'tun-in',
        'protocol': 'tun',
        'settings': {'name': 'xray0', 'mtu': s.get<int>('mtu')},
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
      // Optional: share the tunnel with other devices on the same Wi-Fi / hotspot.
      if (lanListen) ...[
        {
          'tag': 'lan-socks',
          'listen': '0.0.0.0',
          'port': socksPort + 10,
          'protocol': 'socks',
          'settings': {
            'udp': true,
            'auth': lanAuth ? 'password' : 'noauth',
            if (lanAuth) 'accounts': [{'user': user, 'pass': pass}],
          },
          'sniffing': sniffing(),
        },
        {
          'tag': 'lan-http',
          'listen': '0.0.0.0',
          'port': socksPort + 11,
          'protocol': 'http',
          'settings': {if (lanAuth) 'accounts': [{'user': user, 'pass': pass}]},
          'sniffing': sniffing(),
        },
      ],
    ],
    'outbounds': outbounds,
    'routing': {
      'domainStrategy': s.get<String>('domainStrategy'),
      'rules': rules,
      if (balance)
        'balancers': [
          {
            'tag': 'proxy-balance',
            'selector': ['proxy-'],
            'strategy': {'type': s.get<String>('failoverMode')},
          }
        ],
    },
    if (balance && s.get<String>('failoverMode') == 'leastPing')
      'observatory': {
        'subjectSelector': ['proxy-'],
        'probeURL': 'https://www.gstatic.com/generate_204',
        'probeInterval': '${s.get<int>('probeSeconds')}s',
      },
  };

  final over = s.get<String>('xrayJson').trim();
  if (over.isNotEmpty) {
    try {
      final j = _tryDecode(over);
      if (j != null) return _deepMerge(cfg, j);
    } catch (_) {}
  }
  return cfg;
}

Map<String, dynamic>? _tryDecode(String text) {
  final j = jsonDecode(text);
  return j is Map<String, dynamic> ? j : null;
}

Map<String, dynamic> _sockopt(AppSettings s, {String? dialer}) {
  final ka = s.get<int>('tcpKeepAlive');
  final ds = s.get<String>('sockoptDomainStrategy');
  return {
    if (dialer != null) 'dialerProxy': dialer,
    if (s.get<bool>('tcpFastOpen')) 'tcpFastOpen': true,
    if (s.get<bool>('tcpMptcp')) 'tcpMptcp': true,
    if (ka > 0) 'tcpKeepAliveIdle': ka,
    if (ds != 'AsIs') 'domainStrategy': ds,
  };
}

Map<String, dynamic> _proxyOutbound(ServerConfig c, AppSettings s, int? sshPort, bool fragment, String tag, String? chainTag) {
  final out = <String, dynamic>{'tag': tag};
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
  out['streamSettings'] = _stream(c, s, fragment, chainTag);
  if (s.get<bool>('mux') && c.p('flow').isEmpty) {
    out['mux'] = {
      'enabled': true,
      'concurrency': s.get<int>('muxConcurrency'),
      'xudpConcurrency': s.get<int>('xudpConcurrency'),
      'xudpProxyUDP443': s.get<String>('xudpProxyUDP443'),
    };
  }
  return out;
}

Map<String, dynamic> _stream(ServerConfig c, AppSettings s, bool fragment, String? chainTag) {
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

  final fp = c.p('fp').isNotEmpty ? c.p('fp') : s.get<String>('defaultFp');
  final sni = c.p('sni').isNotEmpty ? c.p('sni') : (host.isNotEmpty ? host : c.host);
  if (sec == 'tls') {
    st['tlsSettings'] = {
      'serverName': sni,
      'allowInsecure': s.get<bool>('allowInsecure'),
      if (fp.isNotEmpty) 'fingerprint': fp,
      if (c.p('alpn').isNotEmpty) 'alpn': c.p('alpn').split(','),
    };
  } else if (sec == 'reality') {
    st['realitySettings'] = {
      'serverName': sni,
      'fingerprint': fp.isEmpty ? 'chrome' : fp,
      'publicKey': c.p('pbk'),
      'shortId': c.p('sid'),
      'spiderX': c.p('spx'),
    };
  }
  final dialer = (fragment && sec != 'none') ? 'fragment' : chainTag;
  final so = _sockopt(s, dialer: dialer);
  if (so.isNotEmpty) st['sockopt'] = so;
  return st;
}
