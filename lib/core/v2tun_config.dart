import 'dart:convert';

import 'models.dart';

/// Thrown for profile settings that v2tun cannot carry. The caller shows the message instead of
/// connecting with a weaker or different setup than the profile asks for (e.g. a pinned certificate
/// that would silently stop being checked).
class V2TunUnsupported implements Exception {
  V2TunUnsupported(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Plain-IP DNS servers for the selected preset (also handed to the VPN interface).
List<String> dnsServersFor(AppSettings s) => switch (s.get<String>('dnsPreset')) {
      'cloudflare' => ['1.1.1.1', '1.0.0.1'],
      'google' => ['8.8.8.8', '8.8.4.4'],
      'quad9' => ['9.9.9.9', '149.112.112.112'],
      'adguard' => ['94.140.14.14', '94.140.15.15'],
      _ => [s.get<String>('dns1'), s.get<String>('dns2')],
    };

/// Custom routing lines, one per rule:  `proxy|direct|block  domain:example.com, geosite:google, ip:10.0.0.0/8`
/// Extra selectors: `port:443`, `port:1000-2000`, `protocol:bittorrent`.
/// Bare words are treated as `domain:`. Lines starting with # are ignored.
/// The result is a list of v2tun routing rules. `geosite:X` / `geoip:XX` entries only match when the app
/// supplied a list of exactly that name (see [routeListUrls]); otherwise they never match.
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
      'action': action,
      if (domains.isNotEmpty) 'domain': domains,
      if (ips.isNotEmpty) 'ip': ips,
      if (port != null) 'port': port,
      if (protocols.isNotEmpty) 'protocol': protocols,
    });
  }
  return out;
}

/// Plain-text lists the routing settings refer to, by the name v2tun expects (name -> download URL).
/// v2tun has no geo database: the app downloads these and hands them over with SetRouteList(s).
/// Sources: Loyalsoldier/v2ray-rules-dat (domain lists, same release host as the old geo files) and
/// Loyalsoldier/geoip (one CIDR list per country).
Map<String, String> routeListUrls(AppSettings s) {
  final base = s.get<String>('geoBase');
  final cc = s.get<String>('bypassCountry');
  return {
    if (s.get<String>('routing') == 'bypassLanAds') 'geosite:category-ads-all': '$base/reject-list.txt',
    if (cc == 'cn') 'geosite:cn': '$base/direct-list.txt',
    if (cc != 'none') 'geoip:$cc': 'https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/$cc.txt',
  };
}

Map<String, dynamic> _routing(AppSettings s) {
  final routing = s.get<String>('routing');
  final cc = s.get<String>('bypassCountry');
  return {
    'default': 'proxy',
    'domainStrategy': s.get<String>('domainStrategy').toLowerCase(), // asis | ipifnonmatch | ipondemand
    'bypassLan': routing != 'global',
    'blockQuic': s.get<bool>('blockQuic'),
    'blockBittorrent': s.get<bool>('blockBittorrent'),
    'rules': [
      ...parseCustomRules(s.get<String>('customRules')),
      if (routing == 'bypassLanAds')
        {
          'action': 'block',
          'domain': ['geosite:category-ads-all']
        },
      if (cc == 'cn')
        {
          'action': 'direct',
          'domain': ['geosite:cn']
        },
      if (cc != 'none')
        {
          'action': 'direct',
          'ip': ['geoip:$cc']
        },
      if (cc == 'ir' || cc == 'ru')
        {
          'action': 'direct',
          'domain': ['domain:$cc']
        },
    ],
  };
}

Map<String, dynamic> _deepMerge(Map<String, dynamic> base, Map<String, dynamic> over) {
  final out = Map<String, dynamic>.from(base);
  over.forEach((k, v) {
    final cur = out[k];
    out[k] = (cur is Map<String, dynamic> && v is Map<String, dynamic>) ? _deepMerge(cur, v) : v;
  });
  return out;
}

/// "100-200" -> [100, 200]; "50" -> [50, 50]; anything unreadable -> [fallback].
List<int> _range(String text, List<int> fallback) {
  final m = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+))?\s*$').firstMatch(text);
  if (m == null) return fallback;
  final a = int.parse(m[1]!), b = int.parse(m[2] ?? m[1]!);
  return a <= b ? [a, b] : [b, a];
}

/// uTLS fingerprints v2tun knows: chrome, firefox, safari, ios, android, edge, random.
String _fingerprint(String fp) => switch (fp.toLowerCase()) {
      '' => '',
      'randomized' || 'random' => 'random',
      'chrome' || 'firefox' || 'safari' || 'ios' || 'android' || 'edge' => fp.toLowerCase(),
      _ => 'chrome',
    };

/// Builds the v2tun JSON (the `Config` of github.com/CipherTun/V2-TUN) for a profile.
///
/// The TUN device, DNS capture, fake-IP DNS and sniffing are not part of this JSON: they are options of
/// `Mobile.StartTunEx` (see VpnBridge). The JSON carries the outbound, the transport chain and routing.
///
/// [onWarn] receives things that are ignored on purpose. Settings v2tun cannot honor and that would change
/// what the profile means throw [V2TunUnsupported] instead.
///
/// The `xrayJson` setting (kept under its old key) is deep-merged over the result as a power-user override.
Map<String, dynamic> buildV2TunConfig(ServerConfig c, AppSettings s, {void Function(String message)? onWarn}) {
  final dns = dnsServersFor(s).firstWhere((e) => e.trim().isNotEmpty, orElse: () => '1.1.1.1').trim();
  final cfg = <String, dynamic>{
    'protocol': switch (c.proto) {
      Proto.vless => 'vless',
      Proto.vmess => 'vmess',
      Proto.trojan => 'trojan',
      Proto.shadowsocks => 'shadowsocks',
      Proto.ssh => 'ssh',
    },
    'server': c.host,
    'port': c.port,
    'directDns': dns.contains(':') && !dns.contains('.') ? '[$dns]:53' : '$dns:53',
    'routing': _routing(s),
  };

  if (s.get<String>('failoverMode') != 'off') {
    onWarn?.call('Failover / load balancing is not available with the v2tun core yet; only the selected server is used.');
  }
  if (s.get<String>('chainId').isNotEmpty) {
    onWarn?.call('Double hop is not available with the v2tun core yet; connecting to the selected server directly.');
  }
  if (s.get<bool>('allowLan')) {
    onWarn?.call('Sharing the tunnel on the LAN is not available with the v2tun core yet.');
  }

  if (c.proto == Proto.ssh) {
    _ssh(cfg, c, s, onWarn);
  } else {
    _proxy(cfg, c, s, onWarn);
  }

  final over = s.get<String>('xrayJson').trim();
  if (over.isNotEmpty) {
    try {
      final j = jsonDecode(over);
      if (j is Map<String, dynamic>) return _deepMerge(cfg, j);
      onWarn?.call('The JSON override was ignored: it must be a JSON object.');
    } catch (e) {
      onWarn?.call('The JSON override was ignored: $e');
    }
  }
  return cfg;
}

// ───────── VLESS / VMess / Trojan / Shadowsocks ─────────

void _proxy(Map<String, dynamic> cfg, ServerConfig c, AppSettings s, void Function(String)? onWarn) {
  final who = c.safeHost;
  final net = c.p('net', 'tcp').toLowerCase();
  final network = switch (net) {
    'tcp' || 'raw' => 'tcp',
    'ws' => 'ws',
    'grpc' => 'grpc',
    'xhttp' || 'splithttp' => 'xhttp',
    'httpupgrade' => 'httpupgrade',
    'h2' || 'http' => 'h2',
    'quic' => 'quic',
    _ => throw V2TunUnsupported(
        '$who: the "$net" transport is not supported by the v2tun core (it has tcp, ws, grpc, httpupgrade, h2, xhttp and quic).'),
  };
  final sec = c.p('security', 'none').toLowerCase();
  if (sec != 'none' && sec != 'tls' && sec != 'reality') {
    throw V2TunUnsupported('$who: the "$sec" security type is not supported by the v2tun core.');
  }
  if (network != 'tcp') cfg['network'] = network;

  switch (c.proto) {
    case Proto.vless:
      cfg['uuid'] = c.p('id');
      final enc = c.p('encryption', 'none');
      if (enc != 'none') throw V2TunUnsupported('$who: VLESS encryption "$enc" is not supported by the v2tun core.');
      if (c.p('flow').isNotEmpty) cfg['flow'] = c.p('flow'); // xtls-rprx-vision; the core validates it
    case Proto.vmess:
      cfg['uuid'] = c.p('id');
      cfg['alterId'] = int.tryParse(c.p('aid', '0')) ?? 0;
      final m = c.p('method', 'auto').toLowerCase();
      if (!{'auto', 'aes-128-gcm', 'chacha20-poly1305', 'none'}.contains(m)) {
        throw V2TunUnsupported('$who: the VMess cipher "$m" is not supported by the v2tun core.');
      }
      cfg['method'] = m;
    case Proto.trojan:
      cfg['password'] = c.p('id');
    case Proto.shadowsocks:
      cfg['method'] = c.p('method', 'aes-256-gcm');
      cfg['password'] = c.p('id');
    case Proto.ssh:
      break; // handled by _ssh
  }

  final host = c.p('host'), path = c.p('path');
  switch (network) {
    case 'ws' || 'httpupgrade' || 'h2' || 'xhttp':
      cfg['ws'] = {'host': host, 'path': path.isEmpty ? '/' : path};
      if (network == 'xhttp' && c.p('mode').isNotEmpty) cfg['xhttpMode'] = c.p('mode');
    case 'grpc':
      cfg['grpcService'] = c.p('serviceName');
      cfg['ws'] = {'host': host};
  }

  final fp = _fingerprint(c.p('fp').isNotEmpty ? c.p('fp') : s.get<String>('defaultFp'));
  final sni = c.p('sni').isNotEmpty ? c.p('sni') : (host.isNotEmpty ? host : c.host);
  final alpn = c.p('alpn').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (sec == 'tls') {
    if (c.p('pcs').isNotEmpty) {
      throw V2TunUnsupported(
          '$who: this profile pins the server certificate (pcs), which the v2tun core cannot do yet. Remove the pin or use another core.');
    }
    if (c.p('vcn').isNotEmpty) onWarn?.call('$who: "verify certificate by name" is ignored; the certificate is checked against the SNI.');
    if (c.p('ech').isNotEmpty) onWarn?.call('$who: ECH is not supported by the v2tun core; the SNI is sent in clear text.');
    cfg['tls'] = {
      'enabled': true,
      'sni': sni,
      if (alpn.isNotEmpty) 'alpn': alpn,
      'allowInsecure': s.get<bool>('allowInsecure') || c.p('allowInsecure') == '1',
      if (fp.isNotEmpty) 'fingerprint': fp,
    };
  } else if (sec == 'reality') {
    cfg['reality'] = {
      'publicKey': c.p('pbk'),
      'shortId': c.p('sid'),
      'serverName': sni,
      'fingerprint': fp.isEmpty ? 'chrome' : fp,
    };
    if (alpn.isNotEmpty) cfg['tls'] = {'alpn': alpn};
    if (c.p('spx').isNotEmpty) onWarn?.call('$who: the REALITY spiderX path is ignored by the v2tun core.');
  }

  if (s.get<bool>('fragment') && sec != 'none' && network != 'quic') {
    cfg['fragment'] = {
      'length': _range(s.get<String>('fragLength'), [100, 200]),
      'interval': _range(s.get<String>('fragInterval'), [10, 20]),
    };
  }
  if (s.get<bool>('mux') && c.p('flow').isEmpty) {
    cfg['mux'] = {'enabled': true, 'concurrency': s.get<int>('muxConcurrency')};
  }
}

// ───────── SSH ─────────

void _ssh(Map<String, dynamic> cfg, ServerConfig c, AppSettings s, void Function(String)? onWarn) {
  final who = c.safeHost;
  if (s.get<String>('sshJumpId').isNotEmpty) {
    throw V2TunUnsupported(
        'SSH jump hosts are not supported by the v2tun core. Clear the jump host in Settings → SSH to connect directly.');
  }
  if (c.p('passphrase').isNotEmpty) {
    throw V2TunUnsupported('$who: encrypted private keys (passphrase) are not supported by the v2tun core yet.');
  }
  if (s.get<String>('sshHostKeyPolicy') != 'off') {
    onWarn?.call('SSH host keys are not verified: the v2tun core accepts any server key.');
  }

  cfg['username'] = c.p('user', 'root');
  cfg['password'] = c.p('id');
  if (c.p('privateKey').isNotEmpty) cfg['privateKey'] = c.p('privateKey');
  cfg['timeoutSec'] = s.get<int>('sshConnectTimeout');

  final insecure = c.p('tlsInsecure') == '1' || s.get<bool>('allowInsecure');
  switch (c.p('transport', 'direct')) {
    case 'tls':
      cfg['tls'] = {'enabled': true, 'sni': c.p('sni', c.host), 'allowInsecure': insecure};
    case 'http':
      _sshHttp(cfg, c, s, insecure, onWarn);
  }
}

const _tlsPorts = {443, 8443, 2053, 2083, 2087, 2096};

/// HTTP-proxy / payload transport, the way HTTP Injector and HTTP Custom do it: connect to the proxy
/// (optionally inside TLS), send the payload, read the reply, then speak SSH over the same connection.
/// A payload that is a single `Upgrade: websocket` request is carried by the library's WebSocket transport
/// (real RFC 6455 framing). Anything else is sent as a payload and the HTTP reply is consumed.
void _sshHttp(Map<String, dynamic> cfg, ServerConfig c, AppSettings s, bool insecure, void Function(String)? onWarn) {
  final proxyHost = c.p('proxyHost', c.host);
  final proxyPort = int.tryParse(c.p('proxyPort')) ?? c.port;
  final plan = planPayload(c.p('payload'), c.host, c.port);
  final useTls = plan.sni != null || plan.forceTls || (!plan.forcePlain && _tlsPorts.contains(proxyPort));
  final tlsSni = plan.sni ?? plan.hostHeader ?? proxyHost;

  cfg['server'] = proxyHost;
  cfg['port'] = proxyPort;
  if (useTls) cfg['tls'] = {'enabled': true, 'sni': tlsSni, 'allowInsecure': insecure};

  if (plan.websocket) {
    cfg['network'] = 'ws';
    cfg['ws'] = {'host': plan.hostHeader ?? proxyHost, 'path': plan.path};
    return;
  }

  // The payload already names the real SSH server (literal host:port), so the TCP connection can go
  // straight to the proxy and no library-side proxy mode is needed.
  final rewrite = RegExp(r'^([3-5]\d{2})\s*=\s*200$').firstMatch(c.p('responseRewrite').trim());
  cfg['payload'] = {
    'template': plan.template,
    'stage': useTls ? 'post-tls' : 'pre-tls',
    'expectResponse': true,
    'expectResponses': plan.requests > 0 ? plan.requests : 1,
    if (rewrite != null) 'expectCodes': [101, 200, 201, 202, 203, 204, 205, 206, int.parse(rewrite[1]!)],
  };
  if (rewrite != null) {
    onWarn?.call('${c.safeHost}: the response override ${rewrite[1]}=200 is applied without checking that the reply has no body.');
  }
}

/// What [planPayload] learned about a payload written in the app's HTTP Injector style.
class PayloadPlan {
  const PayloadPlan({
    required this.template,
    required this.requests,
    required this.websocket,
    required this.path,
    this.sni,
    this.forceTls = false,
    this.forcePlain = false,
    this.hostHeader,
  });

  /// Template in v2tun syntax (timing, random and header tags left for the core to expand).
  final String template;

  /// Number of HTTP request lines (one reply is expected for each).
  final int requests;

  /// True when the payload is a single `Upgrade: websocket` request.
  final bool websocket;

  /// Request path of the first request (used for the WebSocket transport).
  final String path;

  final String? sni;
  final bool forceTls, forcePlain;
  final String? hostHeader;
}

String _sub(String t, String name, String value) => t.replaceAll(RegExp('\\[$name\\]', caseSensitive: false), value);

/// Translates the payload dialect of this app into v2tun's:
///
///  * `[sni=name]`, `[tls]`, `[plain]` are app-level switches and are removed (reported in the plan);
///  * `[host]`, `[port]`, `[host_port]`, `[method]` (always CONNECT), `[protocol]`, `[netData]` become literals
///    for the SSH server, so the TCP connection can go to a different proxy;
///  * `[split]` (250 ms) and `[delay_split]` (1.5 s) become `[delay=MS]` (v2tun's `[split]` has no pause);
///    `[instant_split]` is the same in both;
///  * `[rotate=a;b;c]` picks one at random, as before: it becomes `[random=a|b|c]`;
///  * `[ua]` is a random browser User-Agent per connection (`[rand_ua]`), `[random]` an 8 character word.
///
/// Tags that v2tun knows natively ([crlf], [rand_hex=N], [b64=...], [repeat=N] ...) pass through untouched.
PayloadPlan planPayload(String raw, String host, int port) {
  var t = raw.trim().isEmpty ? 'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf][crlf]' : raw;

  String? sni;
  t = t.replaceAllMapped(RegExp(r'\[sni=([^\]]+)\]', caseSensitive: false), (m) {
    sni = m[1]!.trim();
    return '';
  });
  final tlsRe = RegExp(r'\[tls\]', caseSensitive: false), plainRe = RegExp(r'\[plain\]', caseSensitive: false);
  final forceTls = tlsRe.hasMatch(t), forcePlain = plainRe.hasMatch(t);
  t = t.replaceAll(tlsRe, '').replaceAll(plainRe, '');

  t = t.replaceAllMapped(
      RegExp(r'\[rotate=([^\]]+)\]', caseSensitive: false), (m) => '[random=${m[1]!.split(RegExp(r'[;|]')).join('|')}]');
  t = _sub(t, 'ua', '[rand_ua]');
  t = _sub(t, 'random', '[rand_str=8]');
  t = _sub(t, 'delay_split', '[delay=1500]');
  t = _sub(t, 'split', '[delay=250]');

  t = _sub(t, 'netData', 'CONNECT $host:$port HTTP/1.1');
  t = _sub(t, 'method', 'CONNECT');
  t = _sub(t, 'protocol', 'HTTP/1.1');
  t = _sub(t, 'host_port', '$host:$port');
  t = _sub(t, 'host', host);
  t = _sub(t, 'port', '$port');

  // Look at the payload with line endings resolved to find the requests and their headers.
  var view = t;
  for (final e in const {'crlf': '\r\n', 'lfcr': '\n\r', 'cr': '\r', 'lf': '\n'}.entries) {
    view = _sub(view, e.key, e.value);
  }
  view = view.replaceAll(r'\r', '\r').replaceAll(r'\n', '\n');

  final reqRe = RegExp(r'^\s*([A-Za-z]+)\s+(\S+)\s+HTTP/\d(?:\.\d)?', multiLine: true, caseSensitive: false);
  final reqs = reqRe.allMatches(view).toList();
  String? header(String name) =>
      RegExp('^$name:\\s*([^\\r\\n]+)', multiLine: true, caseSensitive: false).firstMatch(view)?[1]?.trim();
  var hostHeader = header('host');
  if (hostHeader != null && hostHeader.contains(':') && !hostHeader.contains(']')) {
    hostHeader = hostHeader.split(':').first;
  }
  final upgrade = (header('upgrade') ?? '').toLowerCase();

  return PayloadPlan(
    template: t,
    requests: reqs.length,
    websocket: reqs.length == 1 && upgrade == 'websocket',
    path: reqs.isEmpty ? '/' : reqs.first[2]!,
    sni: sni,
    forceTls: forceTls,
    forcePlain: forcePlain,
    hostHeader: hostHeader,
  );
}
