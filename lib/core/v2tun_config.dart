import 'models.dart';

/// Thrown when a profile uses something the tunnel library cannot honour. The text is shown to the person.
class V2tunConfigError implements Exception {
  V2tunConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Plain-IP DNS servers for the selected preset (handed to the VPN interface and used as the tunnel's DNS upstream).
List<String> dnsServersFor(AppSettings s) => switch (s.get<String>('dnsPreset')) {
      'cloudflare' => ['1.1.1.1', '1.0.0.1'],
      'google' => ['8.8.8.8', '8.8.4.4'],
      'quad9' => ['9.9.9.9', '149.112.112.112'],
      'adguard' => ['94.140.14.14', '94.140.15.15'],
      _ => [s.get<String>('dns1'), s.get<String>('dns2')],
    };

/// Route list names used by the built-in switches. V2-TUN bundles no country data: the app downloads text lists
/// and hands them over with SetRouteLists (see route_lists.dart).
const kAdsList = 'geosite:category-ads-all';
const kCnSites = 'geosite:cn';

/// Custom routing lines, one per rule:  `proxy|direct|block  domain:example.com, geoip:cn, ip:10.0.0.0/8`
/// Extra selectors: `port:443`, `port:1000-2000`, `protocol:bittorrent` (http, tls, bittorrent, ssh).
/// Bare words are treated as `domain:`. Lines starting with # are ignored. Output is a V2-TUN `routing.rules` list.
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
    for (final m in line.substring(sp).split(RegExp(r'[,\s]+'))) {
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
      'name': 'custom#${out.length + 1}',
      'action': action,
      if (domains.isNotEmpty) 'domain': domains,
      if (ips.isNotEmpty) 'ip': ips,
      if (port != null) 'port': port,
      if (protocols.isNotEmpty) 'protocol': protocols,
    });
  }
  return out;
}

/// Lists the current routing settings need: list name -> download URL. Rules that name a list without a source
/// are reported through [onWarn] (they never match, V2-TUN does not guess).
Map<String, String> routeListSources(AppSettings s, {void Function(String message)? onWarn}) {
  final out = <String, String>{};
  final rules = s.get<String>('customRules');
  final cc = s.get<String>('bypassCountry');
  final ipBase = s.get<String>('listIpBase').replaceAll(RegExp(r'/+$'), '');
  void ip(String code) {
    final c = code.toLowerCase();
    out['geoip:$c'] = '$ipBase/$c.txt';
  }

  if (s.get<String>('routing') == 'bypassLanAds' || rules.contains(kAdsList)) out[kAdsList] = s.get<String>('listAdsUrl');
  if (cc != 'none') {
    ip(cc);
    if (cc == 'cn') out[kCnSites] = s.get<String>('listDirectUrl');
  }
  if (rules.contains(kCnSites)) out[kCnSites] = s.get<String>('listDirectUrl');
  for (final m in RegExp(r'geoip:([a-zA-Z]{2})\b').allMatches(rules)) {
    ip(m[1]!);
  }
  final warned = <String>{};
  for (final m in RegExp(r'geosite:([\w!@.\-]+)').allMatches(rules)) {
    final n = 'geosite:${m[1]!.toLowerCase()}';
    if (n != kAdsList && n != kCnSites && warned.add(n)) {
      onWarn?.call('No list source for $n: rules that use it never match. Only geosite:cn and geosite:category-ads-all are downloaded.');
    }
  }
  return out;
}

(int, int) _pair(String v, int a, int b) {
  final m = RegExp(r'^\s*(\d+)\s*[-,:]\s*(\d+)\s*$').firstMatch(v);
  if (m != null) return (int.parse(m[1]!), int.parse(m[2]!));
  final n = int.tryParse(v.trim());
  return n != null ? (n, n) : (a, b);
}

/// uTLS names the library accepts: chrome, firefox, safari, ios, android, edge, random. Xray-style links also say
/// "randomized"; V2-TUN rejects unknown names instead of quietly sending Go's own recognisable hello.
String normalizeFingerprint(String v) {
  final l = v.trim().toLowerCase();
  return switch (l) {
    'randomized' || 'randomizedalpn' || 'randomizednoalpn' => 'random',
    _ => l,
  };
}

/// Result of [migratePayload].
class PayloadMigration {
  PayloadMigration(this.template, {this.sni, this.warnings = const []});
  final String template;
  final String? sni;
  final List<String> warnings;
}

/// Payloads written for the old engine use a few spellings V2-TUN does not know: `[rotate=a;b]` (now `a|b`),
/// `[sni=name]` (now the profile's SNI) and the `[tls]` / `[plain]` switches (now the security setting).
PayloadMigration migratePayload(String tpl) {
  String? sni;
  final warn = <String>[];
  var t = tpl.replaceAllMapped(RegExp(r'\[sni=([^\]]*)\]', caseSensitive: false), (m) {
    sni = m[1];
    return '';
  });
  if (RegExp(r'\[(tls|plain)\]', caseSensitive: false).hasMatch(t)) {
    t = t.replaceAll(RegExp(r'\[(tls|plain)\]', caseSensitive: false), '');
    warn.add('The [tls] and [plain] tags were removed: choose TLS or plain in the Security setting and the payload stage instead.');
  }
  t = t.replaceAllMapped(RegExp(r'\[(rotate|random)=([^\]]*)\]', caseSensitive: false), (m) {
    final body = m[2]!;
    return body.contains('|') || !body.contains(';') ? m[0]! : '[${m[1]}=${body.replaceAll(';', '|')}]';
  });
  return PayloadMigration(t, sni: sni, warnings: warn);
}

/// "301=200, 3xx=200" -> {"301": 200, "3xx": 200}
Map<String, int> parseResponseMap(String text) {
  final out = <String, int>{};
  for (final part in text.split(RegExp(r'[,;\s]+'))) {
    final kv = part.split('=');
    if (kv.length != 2) continue;
    final v = int.tryParse(kv[1].trim());
    if (v != null) out[kv[0].trim().toLowerCase()] = v;
  }
  return out;
}

const _nets = {'tcp', 'ws', 'httpupgrade', 'h2', 'http', 'grpc', 'quic', 'xhttp', 'splithttp'};

/// Builds the V2-TUN JSON config for a profile (the format of v2tun.Config).
///
/// [forPing] leaves routing out so a latency test always goes through the server.
/// [backups] are complete profiles tried in order, after [c], when [c] cannot connect (V2-TUN `backups`: the one
/// that worked last is tried first next time). A backup the library cannot carry is skipped with a warning.
/// [asBackup] builds the entry of a `backups` list: V2-TUN wants routing, udpgw and directDns only at the top level.
/// [onWarn] receives things that were changed or left out on purpose.
/// Throws [V2tunConfigError] for settings the tunnel library cannot honour: a connection that silently ignores
/// them would only fail later (or, for certificate pinning, run unpinned).
Map<String, dynamic> buildV2tunConfig(
  ServerConfig c,
  AppSettings s, {
  bool forPing = false,
  bool asBackup = false,
  List<ServerConfig> backups = const [],
  void Function(String message)? onWarn,
}) {
  final p = c.proto;
  final cfg = <String, dynamic>{
    'protocol': p.libName,
    'server': c.host,
    'port': c.port,
    'timeoutSec': s.get<int>('connectTimeout'),
    if (!asBackup) 'directDns': s.get<String>('directDns'),
  };

  final insecure = s.get<bool>('allowInsecure') || c.p('allowInsecure') == '1';
  final fp = normalizeFingerprint(c.p('fp').isNotEmpty ? c.p('fp') : s.get<String>('defaultFp'));
  final host = c.p('host');
  final sniOr = c.p('sni').isNotEmpty ? c.p('sni') : (host.isNotEmpty ? host : c.host);

  if (c.p('pcs').isNotEmpty || c.p('vcn').isNotEmpty || c.p('ech').isNotEmpty) {
    throw V2tunConfigError('This profile needs certificate pinning, a verify name or ECH. The tunnel library does not support them yet, and ignoring them would weaken the connection.');
  }

  switch (p) {
    case Proto.vless:
      if (c.p('encryption', 'none') != 'none') throw V2tunConfigError('VLESS encryption "${c.p('encryption')}" is not supported.');
      cfg['uuid'] = c.p('id');
      if (c.p('flow').isNotEmpty) cfg['flow'] = c.p('flow');
    case Proto.vmess:
      cfg['uuid'] = c.p('id');
      cfg['alterId'] = int.tryParse(c.p('aid', '0')) ?? 0;
      cfg['method'] = c.p('method', 'auto');
    case Proto.trojan:
      cfg['password'] = c.p('id');
    case Proto.shadowsocks:
      cfg['method'] = c.p('method', 'aes-256-gcm');
      cfg['password'] = c.p('id');
    case Proto.ssh:
      cfg['username'] = c.p('user');
      cfg['password'] = c.p('id');
      if (c.p('privateKey').isNotEmpty) cfg['privateKey'] = c.p('privateKey');
      if (c.p('passphrase').isNotEmpty) onWarn?.call('SSH key passphrases are not supported by the tunnel library; use an unencrypted private key.');
      // Host key pin: an OpenSSH "SHA256:..." fingerprint or 64 hex characters (profile parameter `hostKey`).
      // The app fills it in on the first connection (trust on first use, see AppState); a changed key is refused.
      final pin = c.p('hostKey').trim();
      if (pin.isNotEmpty) {
        cfg['advanced'] = {'sshHostKey': pin};
      } else {
        onWarn?.call('${c.host}: no SSH host key is pinned yet, so any host key is accepted.');
      }
    case Proto.socks5:
    case Proto.socks4:
    case Proto.http:
    case Proto.https:
      cfg['username'] = c.p('user');
      cfg['password'] = c.p('id');
    case Proto.hysteria2:
      cfg['password'] = c.p('id');
      cfg['tls'] = {'sni': sniOr, 'allowInsecure': insecure};
      cfg['hysteria'] = {
        if (c.p('obfs').isNotEmpty) 'obfs': c.p('obfs'),
        if (c.p('pin').isNotEmpty) 'pinSha256': c.p('pin'),
        if ((int.tryParse(c.p('downMbps')) ?? 0) > 0) 'downMbps': int.parse(c.p('downMbps')),
      };
    case Proto.hysteria1:
      cfg['password'] = c.p('id');
      cfg['tls'] = {'sni': sniOr, 'allowInsecure': insecure};
      cfg['hysteria'] = {
        if (c.p('obfs').isNotEmpty) 'obfs': c.p('obfs'),
        if (c.p('alpn').isNotEmpty) 'alpn': c.p('alpn'),
        if ((int.tryParse(c.p('upMbps')) ?? 0) > 0) 'upMbps': int.parse(c.p('upMbps')),
        if ((int.tryParse(c.p('downMbps')) ?? 0) > 0) 'downMbps': int.parse(c.p('downMbps')),
      };
  }

  var tlsOrReality = p.isHysteria;
  if (!p.isHysteria) {
    final net = c.p('net', 'tcp').toLowerCase();
    if (!_nets.contains(net)) {
      throw V2tunConfigError('The "$net" transport is not supported by the tunnel library (mKCP is not implemented).');
    }
    if (net != 'tcp') cfg['network'] = net == 'splithttp' ? 'xhttp' : net;
    final path = c.p('path');
    if (net == 'ws' || net == 'httpupgrade' || net == 'h2' || net == 'http' || net == 'xhttp' || net == 'splithttp') {
      cfg['ws'] = {if (host.isNotEmpty) 'host': host, 'path': path.isEmpty ? '/' : path};
    }
    if (net == 'grpc') cfg['grpcService'] = c.p('serviceName');
    if (net == 'xhttp' || net == 'splithttp') {
      if (c.p('mode').isNotEmpty) cfg['xhttpMode'] = c.p('mode');
    }

    final sec = p == Proto.https ? 'tls' : c.p('security', 'none');
    if (sec == 'tls') {
      tlsOrReality = true;
      cfg['tls'] = {
        'enabled': true,
        'sni': sniOr,
        'allowInsecure': insecure,
        if (c.p('alpn').isNotEmpty) 'alpn': c.p('alpn').split(','),
        if (fp.isNotEmpty) 'fingerprint': fp,
      };
    } else if (sec == 'reality') {
      tlsOrReality = true;
      cfg['reality'] = {
        'publicKey': c.p('pbk'),
        'shortId': c.p('sid'),
        'serverName': sniOr,
        'fingerprint': fp.isEmpty ? 'chrome' : fp,
      };
      if (c.p('spx').isNotEmpty) onWarn?.call('REALITY spiderX is ignored by the tunnel library.');
    }

    // Payload (HTTP Injector style), also used for SSH over WebSocket and the remote-proxy mode.
    final tpl = c.p('payload');
    if (tpl.isNotEmpty) {
      final m = migratePayload(tpl);
      for (final w in m.warnings) {
        onWarn?.call(w);
      }
      if (m.sni != null && cfg['tls'] is Map && c.p('sni').isEmpty) (cfg['tls'] as Map)['sni'] = m.sni;
      final map = parseResponseMap(c.p('responseMap'));
      cfg['payload'] = {
        'template': m.template,
        if (c.p('payloadHost').isNotEmpty) 'host': c.p('payloadHost'),
        if (c.p('payloadStage') == 'post-tls') 'stage': 'post-tls',
        if (c.p('proxy').isNotEmpty) 'proxy': c.p('proxy'),
        if (map.isNotEmpty) 'responseMap': map,
      };
    }

    if (s.get<bool>('mux') && p.canMux && c.p('flow').isEmpty) {
      cfg['mux'] = {'enabled': true, 'concurrency': s.get<int>('muxConcurrency')};
    }
    if (s.get<bool>('fragment') && tlsOrReality && net != 'quic') {
      final l = _pair(s.get<String>('fragLength'), 100, 200);
      final i = _pair(s.get<String>('fragInterval'), 10, 20);
      cfg['fragment'] = {'length': [l.$1, l.$2], 'interval': [i.$1, i.$2]};
    }
  }

  if (!asBackup) {
    final gw = s.get<String>('udpgw').trim();
    if (gw.isNotEmpty) cfg['udpgw'] = gw;
  }

  if (!forPing && !asBackup) cfg['routing'] = buildRouting(s, onWarn: onWarn);

  if (!asBackup && backups.isNotEmpty) {
    final list = <Map<String, dynamic>>[];
    for (final b in backups) {
      try {
        list.add(buildV2tunConfig(b, s, asBackup: true, onWarn: onWarn));
      } on V2tunConfigError catch (e) {
        onWarn?.call('Backup ${b.host} skipped: ${e.message}');
      }
    }
    if (list.isNotEmpty) {
      cfg['backups'] = list;
      // V2-TUN gives each server 12 s by default; a slow payload bootstrap can need longer.
      final t = s.get<int>('connectTimeout');
      if (t > 12) cfg['failoverTimeoutSec'] = t;
    }
  }
  return cfg;
}

/// The `routing` section of the V2-TUN config for the current settings. Also what `UpdateRouting` takes to change
/// the rules of a running tunnel.
Map<String, dynamic> buildRouting(AppSettings s, {void Function(String message)? onWarn}) {
  final mode = s.get<String>('routing');
  final cc = s.get<String>('bypassCountry');
  routeListSources(s, onWarn: onWarn); // reports lists without a source
  return {
    'default': 'proxy',
    'domainStrategy': s.get<String>('domainStrategy').toLowerCase(),
    if (mode != 'global') 'bypassLan': true,
    if (s.get<bool>('blockQuic')) 'blockQuic': true,
    if (s.get<bool>('blockBittorrent')) 'blockBittorrent': true,
    'rules': [
      ...parseCustomRules(s.get<String>('customRules')),
      if (mode == 'bypassLanAds') {'name': 'ads', 'action': 'block', 'domain': [kAdsList]},
      if (cc == 'cn') {'name': 'cn-sites', 'action': 'direct', 'domain': [kCnSites]},
      if (cc != 'none') {'name': 'country-ip', 'action': 'direct', 'ip': ['geoip:$cc']},
      if (cc == 'ir' || cc == 'ru') {'name': 'country-tld', 'action': 'direct', 'domain': ['domain:$cc']},
    ],
  };
}
