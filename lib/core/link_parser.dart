import 'dart:convert';

import 'models.dart';

/// Parses share links: vless://, vmess://, trojan://, ss://, ssh://, socks5://, socks4://,
/// hysteria2:// (hy2://), hysteria:// and subscription payloads (plain or base64 list of links).
/// The field names match the V2-TUN link parser (CipherTun/V2-TUN links.go).
/// http:// and https:// are not read as proxy links: they are far more often subscription URLs.
class LinkParser {
  static ServerConfig? parse(String raw) {
    final s = raw.trim();
    try {
      final l = s.toLowerCase();
      if (l.startsWith('vless://')) return _uriStyle(s, Proto.vless);
      if (l.startsWith('trojan://')) return _uriStyle(s, Proto.trojan);
      if (l.startsWith('vmess://')) return _vmess(s);
      if (l.startsWith('ss://')) return _ss(s);
      if (l.startsWith('ssh://')) return _ssh(s);
      if (l.startsWith('socks://') || l.startsWith('socks5://') || l.startsWith('socks5h://')) return _proxy(s, Proto.socks5);
      if (l.startsWith('socks4://') || l.startsWith('socks4a://')) return _proxy(s, Proto.socks4);
      if (l.startsWith('hysteria2://') || l.startsWith('hy2://')) return _hysteria2(s);
      if (l.startsWith('hysteria://') || l.startsWith('hy://')) return _hysteria1(s);
    } catch (_) {}
    return null;
  }

  static List<ServerConfig> parseMany(String text) {
    var body = text.trim();
    if (!body.contains('://')) {
      try {
        body = utf8.decode(base64.decode(base64.normalize(body)));
      } catch (_) {}
    }
    return body.split(RegExp(r'[\r\n]+')).map(parse).whereType<ServerConfig>().toList();
  }

  /// `host:port` (host may be a bracketed IPv6 literal, a trailing `/` is ignored).
  static (String, int) _hostPort(String s) {
    final t = s.replaceAll('/', '');
    final i = t.lastIndexOf(':');
    if (i < 0) throw const FormatException('missing port');
    var h = t.substring(0, i);
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    return (h, int.parse(t.substring(i + 1)));
  }

  /// Host as it must appear inside a URL authority.
  static String _authorityHost(String h) => h.contains(':') ? '[$h]' : h;

  static bool _truthy(String? v) => v == '1' || v?.toLowerCase() == 'true';

  static ServerConfig _uriStyle(String s, Proto proto) {
    final u = Uri.parse(s);
    final q = u.queryParameters;
    final flow = (q['flow'] ?? '').toLowerCase();
    if (flow.isNotEmpty && flow != 'xtls-rprx-vision' && flow != 'xtls-rprx-vision-udp443') {
      throw FormatException('flow $flow is not supported');
    }
    return ServerConfig(
      id: ServerConfig.newId(),
      name: Uri.decodeComponent(u.fragment.isEmpty ? u.host : u.fragment),
      proto: proto,
      host: u.host,
      port: u.hasPort ? u.port : 443,
      params: {
        'id': Uri.decodeComponent(u.userInfo),
        'net': (q['type'] ?? 'tcp') == 'splithttp' ? 'xhttp' : (q['type'] ?? 'tcp'),
        // An explicit security=none (plain VLESS/Trojan, e.g. WebSocket on port 80) is kept as none. Only a
        // Trojan link without any security parameter is read as TLS, because that is what such links mean.
        'security': q['security'] ?? (proto == Proto.trojan ? 'tls' : 'none'),
        'sni': q['sni'] ?? q['peer'] ?? '',
        'fp': q['fp'] ?? '',
        'pbk': q['pbk'] ?? '',
        'sid': q['sid'] ?? '',
        'spx': q['spx'] ?? '',
        'path': q['path'] ?? '',
        'host': q['host'] ?? '',
        'flow': flow,
        'alpn': q['alpn'] ?? '',
        'serviceName': q['serviceName'] ?? '',
        'mode': q['mode'] ?? '',
        'encryption': q['encryption'] ?? 'none',
        // Certificate pinning / name check / ECH are kept so the config builder can refuse them explicitly.
        'pcs': q['pcs'] ?? '',
        'vcn': q['vcn'] ?? '',
        'ech': q['ech'] ?? '',
        'allowInsecure': (_truthy(q['allowInsecure']) || _truthy(q['allow_insecure']) || _truthy(q['insecure'])) ? '1' : '',
      },
    );
  }

  static ServerConfig _vmess(String s) {
    final j = jsonDecode(utf8.decode(base64.decode(base64.normalize(s.substring(8))))) as Map<String, dynamic>;
    String v(String k) => (j[k] ?? '').toString();
    final net = v('net').isEmpty ? 'tcp' : (v('net') == 'splithttp' ? 'xhttp' : v('net'));
    return ServerConfig(
      id: ServerConfig.newId(),
      name: v('ps').isEmpty ? v('add') : v('ps'),
      proto: Proto.vmess,
      host: v('add'),
      port: int.parse(v('port')),
      params: {
        'id': v('id'),
        'aid': v('aid').isEmpty ? '0' : v('aid'),
        'net': net,
        'security': v('tls') == 'tls' ? 'tls' : 'none',
        'sni': v('sni'),
        'fp': v('fp'),
        // v2rayN stores the gRPC service name in `path`.
        'path': net == 'grpc' ? '' : v('path'),
        'serviceName': net == 'grpc' ? v('path') : '',
        'host': v('host'),
        'alpn': v('alpn'),
        'method': v('scy').isEmpty ? 'auto' : v('scy'),
        'allowInsecure': (_truthy(v('allowInsecure')) || _truthy(v('insecure'))) ? '1' : '',
      },
    );
  }

  static ServerConfig _ss(String s) {
    var rest = s.substring(5);
    var name = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      name = Uri.decodeComponent(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    final qi = rest.indexOf('?');
    if (qi >= 0) {
      // obfs-local / v2ray-plugin wrap the connection; ignoring them would produce a profile that never connects.
      if (rest.substring(qi).contains('plugin=')) throw const FormatException('shadowsocks plugins are not supported');
      rest = rest.substring(0, qi);
    }
    late String method, password, host;
    late int port;
    if (rest.contains('@')) {
      // SIP002: base64url(method:password)@host:port  (or plain method:password)
      final at = rest.lastIndexOf('@');
      var cred = rest.substring(0, at);
      if (!cred.contains(':')) {
        cred = utf8.decode(base64.decode(base64.normalize(cred)));
      }
      (host, port) = _hostPort(rest.substring(at + 1));
      method = cred.substring(0, cred.indexOf(':'));
      password = Uri.decodeComponent(cred.substring(cred.indexOf(':') + 1));
    } else {
      final dec = utf8.decode(base64.decode(base64.normalize(rest)));
      final at = dec.lastIndexOf('@');
      final cred = dec.substring(0, at);
      (host, port) = _hostPort(dec.substring(at + 1));
      method = cred.substring(0, cred.indexOf(':'));
      password = cred.substring(cred.indexOf(':') + 1);
    }
    return ServerConfig(
      id: ServerConfig.newId(),
      name: name.isEmpty ? host : name,
      proto: Proto.shadowsocks,
      host: host,
      port: port,
      params: {'method': method, 'id': password},
    );
  }

  /// ssh://user:password@host:port#name
  static ServerConfig _ssh(String s) {
    final u = Uri.parse(s);
    final info = u.userInfo.split(':');
    return ServerConfig(
      id: ServerConfig.newId(),
      name: Uri.decodeComponent(u.fragment.isEmpty ? u.host : u.fragment),
      proto: Proto.ssh,
      host: u.host,
      port: u.hasPort ? u.port : 22,
      params: {
        'user': Uri.decodeComponent(info.first),
        'id': info.length > 1 ? Uri.decodeComponent(info.sublist(1).join(':')) : '',
      },
    );
  }

  /// socks5://user:pass@host:1080#name, socks4://user@host:1080#name
  static ServerConfig _proxy(String s, Proto proto) {
    final u = Uri.parse(s);
    final info = u.userInfo.split(':');
    return ServerConfig(
      id: ServerConfig.newId(),
      name: Uri.decodeComponent(u.fragment.isEmpty ? u.host : u.fragment),
      proto: proto,
      host: u.host,
      port: u.hasPort ? u.port : 1080,
      params: {
        'user': info.first.isEmpty ? '' : Uri.decodeComponent(info.first),
        'id': info.length > 1 ? Uri.decodeComponent(info.sublist(1).join(':')) : '',
      },
    );
  }

  /// hysteria2://auth@host:443/?sni=..&insecure=1&obfs=salamander&obfs-password=..&pinSHA256=..
  static ServerConfig _hysteria2(String s) {
    final u = Uri.parse(s);
    final q = u.queryParameters;
    if (q.containsKey('mport')) throw const FormatException('port hopping is not supported');
    return ServerConfig(
      id: ServerConfig.newId(),
      name: Uri.decodeComponent(u.fragment.isEmpty ? u.host : u.fragment),
      proto: Proto.hysteria2,
      host: u.host,
      port: u.hasPort ? u.port : 443,
      params: {
        'id': Uri.decodeComponent(u.userInfo),
        'sni': q['sni'] ?? q['peer'] ?? '',
        'allowInsecure': _truthy(q['insecure']) ? '1' : '',
        'obfs': (q['obfs'] ?? '') == 'salamander' ? (q['obfs-password'] ?? '') : '',
        'pin': (q['pinSHA256'] ?? '').replaceAll(':', '').toLowerCase(),
        'downMbps': q['downmbps'] ?? '',
      },
    );
  }

  /// hysteria://host:443?auth=..&peer=..&insecure=1&upmbps=..&downmbps=..&alpn=..&obfs=xplus&obfsParam=..
  static ServerConfig _hysteria1(String s) {
    final u = Uri.parse(s);
    final q = u.queryParameters;
    final proto = (q['protocol'] ?? 'udp').toLowerCase();
    if (proto != 'udp') throw FormatException('hysteria protocol $proto (faketcp, wechat-video) is not supported');
    return ServerConfig(
      id: ServerConfig.newId(),
      name: Uri.decodeComponent(u.fragment.isEmpty ? u.host : u.fragment),
      proto: Proto.hysteria1,
      host: u.host,
      port: u.hasPort ? u.port : 443,
      params: {
        'id': q['auth'] ?? '',
        'sni': q['peer'] ?? q['sni'] ?? '',
        'allowInsecure': _truthy(q['insecure']) ? '1' : '',
        'upMbps': q['upmbps'] ?? '',
        'downMbps': q['downmbps'] ?? '',
        'alpn': q['alpn'] ?? '',
        'obfs': (q['obfs'] ?? '') == 'xplus' ? (q['obfsParam'] ?? '') : '',
      },
    );
  }

  /// Share link for export (SSH key profiles, payloads, HTTP and HTTPS proxies are not exportable as links).
  static String? toLink(ServerConfig c) {
    String enc(String x) => Uri.encodeComponent(x);
    final h = _authorityHost(c.host);
    switch (c.proto) {
      case Proto.vless:
      case Proto.trojan:
        final q = <String, String>{
          if (c.p('net', 'tcp') != 'tcp') 'type': c.p('net'),
          // Always written for Trojan, so a plain (security=none) profile does not come back as TLS on import.
          if (c.p('security', 'none') != 'none' || c.proto == Proto.trojan) 'security': c.p('security', 'none'),
          for (final k in ['sni', 'fp', 'pbk', 'sid', 'spx', 'path', 'host', 'flow', 'alpn', 'serviceName', 'mode', 'pcs', 'vcn', 'ech', 'allowInsecure'])
            if (c.p(k).isNotEmpty) k: c.p(k),
          if (c.proto == Proto.vless) 'encryption': c.p('encryption', 'none'),
        };
        final qs = q.entries.map((e) => '${e.key}=${enc(e.value)}').join('&');
        return '${c.proto.name}://${enc(c.p('id'))}@$h:${c.port}?$qs#${enc(c.name)}';
      case Proto.vmess:
        final grpc = c.p('net', 'tcp') == 'grpc';
        final j = {
          'v': '2', 'ps': c.name, 'add': c.host, 'port': '${c.port}', 'id': c.p('id'),
          'aid': c.p('aid', '0'), 'scy': c.p('method', 'auto'), 'net': c.p('net', 'tcp'),
          'type': 'none', 'host': c.p('host'), 'path': grpc ? c.p('serviceName') : c.p('path'),
          'tls': c.p('security') == 'tls' ? 'tls' : '', 'sni': c.p('sni'),
          'fp': c.p('fp'), 'alpn': c.p('alpn'),
          if (c.p('allowInsecure') == '1') 'allowInsecure': '1',
        };
        return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
      case Proto.shadowsocks:
        final cred = base64Url.encode(utf8.encode('${c.p('method')}:${c.p('id')}')).replaceAll('=', '');
        return 'ss://$cred@$h:${c.port}#${enc(c.name)}';
      case Proto.ssh:
        if (c.p('privateKey').isNotEmpty || c.p('payload').isNotEmpty || c.p('security', 'none') != 'none') return null;
        return 'ssh://${enc(c.p('user'))}:${enc(c.p('id'))}@$h:${c.port}#${enc(c.name)}';
      case Proto.socks5:
      case Proto.socks4:
        final cred = c.p('user').isEmpty ? '' : '${enc(c.p('user'))}${c.p('id').isEmpty ? '' : ':${enc(c.p('id'))}'}@';
        return '${c.proto.name}://$cred$h:${c.port}#${enc(c.name)}';
      case Proto.hysteria2:
        final q = <String, String>{
          if (c.p('sni').isNotEmpty) 'sni': c.p('sni'),
          if (c.p('allowInsecure') == '1') 'insecure': '1',
          if (c.p('obfs').isNotEmpty) ...{'obfs': 'salamander', 'obfs-password': c.p('obfs')},
          if (c.p('pin').isNotEmpty) 'pinSHA256': c.p('pin'),
          if (c.p('downMbps').isNotEmpty) 'downmbps': c.p('downMbps'),
        };
        final qs = q.entries.map((e) => '${e.key}=${enc(e.value)}').join('&');
        return 'hysteria2://${enc(c.p('id'))}@$h:${c.port}/?$qs#${enc(c.name)}';
      case Proto.hysteria1:
        final q = <String, String>{
          'auth': c.p('id'),
          if (c.p('sni').isNotEmpty) 'peer': c.p('sni'),
          if (c.p('allowInsecure') == '1') 'insecure': '1',
          if (c.p('upMbps').isNotEmpty) 'upmbps': c.p('upMbps'),
          if (c.p('downMbps').isNotEmpty) 'downmbps': c.p('downMbps'),
          if (c.p('alpn').isNotEmpty) 'alpn': c.p('alpn'),
          if (c.p('obfs').isNotEmpty) ...{'obfs': 'xplus', 'obfsParam': c.p('obfs')},
        };
        final qs = q.entries.map((e) => '${e.key}=${enc(e.value)}').join('&');
        return 'hysteria://$h:${c.port}?$qs#${enc(c.name)}';
      case Proto.http:
      case Proto.https:
        return null;
    }
  }
}
