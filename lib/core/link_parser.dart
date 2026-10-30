import 'dart:convert';

import 'models.dart';

/// Parses share links: vless://, vmess://, trojan://, ss://, ssh://
/// and subscription payloads (plain or base64 list of links).
class LinkParser {
  static ServerConfig? parse(String raw) {
    final s = raw.trim();
    try {
      if (s.startsWith('vless://')) return _uriStyle(s, Proto.vless);
      if (s.startsWith('trojan://')) return _uriStyle(s, Proto.trojan);
      if (s.startsWith('vmess://')) return _vmess(s);
      if (s.startsWith('ss://')) return _ss(s);
      if (s.startsWith('ssh://')) return _ssh(s);
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

  static ServerConfig _uriStyle(String s, Proto proto) {
    final u = Uri.parse(s);
    final q = u.queryParameters;
    return ServerConfig(
      id: ServerConfig.newId(),
      name: Uri.decodeComponent(u.fragment.isEmpty ? u.host : u.fragment),
      proto: proto,
      host: u.host,
      port: u.hasPort ? u.port : 443,
      params: {
        'id': Uri.decodeComponent(u.userInfo),
        'net': q['type'] ?? 'tcp',
        'security': q['security'] ?? (proto == Proto.trojan ? 'tls' : 'none'),
        'sni': q['sni'] ?? q['peer'] ?? '',
        'fp': q['fp'] ?? '',
        'pbk': q['pbk'] ?? '',
        'sid': q['sid'] ?? '',
        'spx': q['spx'] ?? '',
        'path': q['path'] ?? '',
        'host': q['host'] ?? '',
        'flow': q['flow'] ?? '',
        'alpn': q['alpn'] ?? '',
        'serviceName': q['serviceName'] ?? '',
        'mode': q['mode'] ?? '',
        'encryption': q['encryption'] ?? 'none',
      },
    );
  }

  static ServerConfig _vmess(String s) {
    final j = jsonDecode(utf8.decode(base64.decode(base64.normalize(s.substring(8)))))
        as Map<String, dynamic>;
    String v(String k) => (j[k] ?? '').toString();
    return ServerConfig(
      id: ServerConfig.newId(),
      name: v('ps').isEmpty ? v('add') : v('ps'),
      proto: Proto.vmess,
      host: v('add'),
      port: int.parse(v('port')),
      params: {
        'id': v('id'),
        'aid': v('aid').isEmpty ? '0' : v('aid'),
        'net': v('net').isEmpty ? 'tcp' : v('net'),
        'security': v('tls') == 'tls' ? 'tls' : 'none',
        'sni': v('sni'),
        'fp': v('fp'),
        'path': v('path'),
        'host': v('host'),
        'alpn': v('alpn'),
        'method': v('scy').isEmpty ? 'auto' : v('scy'),
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
    rest = rest.split('?').first;
    late String method, password, host;
    late int port;
    if (rest.contains('@')) {
      // SIP002: base64url(method:password)@host:port  (or plain method:password)
      final at = rest.lastIndexOf('@');
      var cred = rest.substring(0, at);
      if (!cred.contains(':')) {
        cred = utf8.decode(base64.decode(base64.normalize(cred)));
      }
      final hp = rest.substring(at + 1).split(':');
      method = cred.substring(0, cred.indexOf(':'));
      password = Uri.decodeComponent(cred.substring(cred.indexOf(':') + 1));
      host = hp[0];
      port = int.parse(hp[1].replaceAll('/', ''));
    } else {
      final dec = utf8.decode(base64.decode(base64.normalize(rest)));
      final at = dec.lastIndexOf('@');
      final cred = dec.substring(0, at);
      final hp = dec.substring(at + 1).split(':');
      method = cred.substring(0, cred.indexOf(':'));
      password = cred.substring(cred.indexOf(':') + 1);
      host = hp[0];
      port = int.parse(hp[1]);
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

  /// Share link for export (SSH key profiles are not exportable).
  static String? toLink(ServerConfig c) {
    String enc(String x) => Uri.encodeComponent(x);
    switch (c.proto) {
      case Proto.vless:
      case Proto.trojan:
        final q = <String, String>{
          if (c.p('net', 'tcp') != 'tcp') 'type': c.p('net'),
          if (c.p('security', 'none') != 'none') 'security': c.p('security'),
          for (final k in ['sni', 'fp', 'pbk', 'sid', 'spx', 'path', 'host', 'flow', 'alpn', 'serviceName', 'mode'])
            if (c.p(k).isNotEmpty) k: c.p(k),
          if (c.proto == Proto.vless) 'encryption': c.p('encryption', 'none'),
        };
        final qs = q.entries.map((e) => '${e.key}=${enc(e.value)}').join('&');
        return '${c.proto.name}://${enc(c.p('id'))}@${c.host}:${c.port}?$qs#${enc(c.name)}';
      case Proto.vmess:
        final j = {
          'v': '2', 'ps': c.name, 'add': c.host, 'port': '${c.port}', 'id': c.p('id'),
          'aid': c.p('aid', '0'), 'scy': c.p('method', 'auto'), 'net': c.p('net', 'tcp'),
          'type': 'none', 'host': c.p('host'), 'path': c.p('path'),
          'tls': c.p('security') == 'tls' ? 'tls' : '', 'sni': c.p('sni'),
        };
        return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
      case Proto.shadowsocks:
        final cred = base64Url.encode(utf8.encode('${c.p('method')}:${c.p('id')}')).replaceAll('=', '');
        return 'ss://$cred@${c.host}:${c.port}#${enc(c.name)}';
      case Proto.ssh:
        if (c.p('privateKey').isNotEmpty) return null;
        return 'ssh://${enc(c.p('user'))}:${enc(c.p('id'))}@${c.host}:${c.port}#${enc(c.name)}';
    }
  }
}
