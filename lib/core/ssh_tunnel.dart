import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

typedef SshLog = void Function(String level, String msg);

/// A plain TCP/TLS socket as an [SSHSocket]. DartSSH2 lets us supply any transport,
/// which is how the TLS-with-custom-SNI and HTTP-payload modes below are implemented.
class _NetSocket implements SSHSocket {
  _NetSocket(this._s, [Stream<Uint8List>? incoming]) : stream = incoming ?? _s;
  final Socket _s;
  @override
  final Stream<Uint8List> stream;
  @override
  StreamSink<List<int>> get sink => _s;
  @override
  Future<void> get done => _s.done;
  @override
  Future<void> close() async => _s.close();
  @override
  void destroy() => _s.destroy();
}

/// SSH transport built on DartSSH2: opens an SSH session and exposes a local
/// SOCKS5 proxy (`ssh -D`). Xray-core's `proxy` outbound points at that port,
/// so the TUN device carries all device traffic through the SSH server.
///
/// Per-profile transports (profile param `transport`):
///  * `direct`: plain TCP
///  * `tls`: SSH inside TLS with an optional custom SNI (`sni`), like stunnel/HAProxy fronts
///  * `http`: SSH after an HTTP proxy handshake with a custom `payload` (`proxyHost`, `proxyPort`)
/// Optionally the whole session can ride through another SSH server (jump host).
class SshTunnel {
  SSHClient? _client;
  SSHClient? _jump;
  dynamic _forward;

  bool get active => _client != null;

  /// Returns the local SOCKS5 port.
  Future<int> start(
    ServerConfig c,
    AppSettings s,
    SharedPreferences prefs,
    SshLog log, {
    void Function()? onDropped,
    ServerConfig? jump,
  }) async {
    await stop();
    final timeout = Duration(seconds: s.get<int>('sshConnectTimeout'));
    final port = s.get<int>('sshLocalPort') > 0 ? s.get<int>('sshLocalPort') : s.get<int>('socksPort') + 2;

    SSHSocket socket;
    if (jump != null) {
      log('info', 'SSH: connecting through jump host ${jump.safeHost}');
      final jc = await _login(jump, s, prefs, log, await _open(jump, s, timeout, log));
      _jump = jc;
      await jc.authenticated;
      log('info', 'SSH: jump host authenticated');
      socket = await jc.forwardLocal(c.host, c.port);
    } else {
      log('info', 'SSH: connecting to ${c.locked ? 'locked server' : '${c.host}:${c.port}'} (${c.p('transport', 'direct')})');
      socket = await _open(c, s, timeout, log);
    }

    final client = await _login(c, s, prefs, log, socket);
    _client = client;
    await client.authenticated.timeout(timeout);
    log('info', c.locked ? 'SSH: authenticated' : 'SSH: authenticated as ${c.p('user', 'root')}');

    _forward = await client.forwardDynamic(
      bindHost: '127.0.0.1',
      bindPort: port,
      options: SSHDynamicForwardOptions(
        handshakeTimeout: const Duration(seconds: 10),
        connectTimeout: timeout,
        maxConnections: s.get<int>('sshMaxConnections'),
      ),
    );
    log('info', 'SSH: SOCKS5 listening on 127.0.0.1:$port');

    client.done.then((_) {
      if (identical(_client, client)) {
        _client = null;
        log('warn', 'SSH: session closed');
        onDropped?.call();
      }
    }).catchError((Object e) {
      if (identical(_client, client)) {
        _client = null;
        log('error', 'SSH: $e');
        onDropped?.call();
      }
    });
    return port;
  }

  // ───────── transports ─────────

  Future<SSHSocket> _open(ServerConfig c, AppSettings s, Duration timeout, SshLog log) async {
    final noDelay = s.get<bool>('sshNoDelay');
    switch (c.p('transport', 'direct')) {
      case 'tls':
        final raw = await Socket.connect(c.host, c.port, timeout: timeout);
        if (noDelay) raw.setOption(SocketOption.tcpNoDelay, true);
        final sni = c.p('sni', c.host);
        final tls = await SecureSocket.secure(
          raw,
          host: sni,
          onBadCertificate: (_) => c.p('tlsInsecure') == '1' || s.get<bool>('allowInsecure'),
        ).timeout(timeout);
        log('info', 'SSH: TLS established${c.locked ? '' : ' (SNI $sni)'}');
        return _NetSocket(tls);
      case 'http':
        return _httpConnect(c, s, timeout, log, noDelay);
      default:
        final raw = await Socket.connect(c.host, c.port, timeout: timeout);
        if (noDelay) raw.setOption(SocketOption.tcpNoDelay, true);
        return _NetSocket(raw);
    }
  }

  /// Placeholders: [host] [port] [host_port] [crlf] [cr] [lf]
  static String expandPayload(String payload, String host, int port) => payload
      .replaceAll('[host_port]', '$host:$port')
      .replaceAll('[host]', host)
      .replaceAll('[port]', '$port')
      .replaceAll('[crlf]', '\r\n')
      .replaceAll('[cr]', '\r')
      .replaceAll('[lf]', '\n')
      .replaceAll('\\r', '\r')
      .replaceAll('\\n', '\n');

  Future<SSHSocket> _httpConnect(ServerConfig c, AppSettings s, Duration timeout, SshLog log, bool noDelay) async {
    final proxyHost = c.p('proxyHost', c.host);
    final proxyPort = int.tryParse(c.p('proxyPort')) ?? c.port;
    final payload = expandPayload(
      c.p('payload', 'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf][crlf]'),
      c.host,
      c.port,
    );
    final raw = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    if (noDelay) raw.setOption(SocketOption.tcpNoDelay, true);

    final ctl = StreamController<Uint8List>();
    final head = BytesBuilder();
    final ready = Completer<void>();
    var passthrough = false;

    int endOfHeaders(List<int> b) {
      for (var i = 0; i + 3 < b.length; i++) {
        if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
      }
      return -1;
    }

    raw.listen(
      (d) {
        if (passthrough) {
          ctl.add(d);
          return;
        }
        head.add(d);
        final bytes = head.toBytes();
        final i = endOfHeaders(bytes);
        if (i < 0) return;
        passthrough = true;
        final first = latin1.decode(bytes.sublist(0, i)).split('\r\n').first;
        if (first.startsWith('HTTP/') && (first.contains(' 200') || first.contains(' 101'))) {
          ready.complete();
          final rest = bytes.sublist(i + 4);
          if (rest.isNotEmpty) ctl.add(Uint8List.fromList(rest));
        } else {
          ready.completeError('The HTTP proxy answered: $first');
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
        ctl.addError(e);
      },
      onDone: () {
        if (!ready.isCompleted) ready.completeError('The HTTP proxy closed the connection');
        ctl.close();
      },
    );
    raw.add(latin1.encode(payload));
    await ready.future.timeout(timeout);
    log('info', 'SSH: HTTP proxy handshake accepted');
    return _NetSocket(raw, ctl.stream);
  }

  // ───────── authentication + host keys ─────────

  Future<SSHClient> _login(ServerConfig c, AppSettings s, SharedPreferences prefs, SshLog log, SSHSocket socket) async {
    final pem = c.p('privateKey');
    final policy = s.get<String>('sshHostKeyPolicy');
    return SSHClient(
      socket,
      username: c.p('user', 'root'),
      identities: pem.isEmpty ? null : SSHKeyPair.fromPem(pem, c.p('passphrase').isEmpty ? null : c.p('passphrase')),
      onPasswordRequest: () => c.p('id'),
      keepAliveInterval: Duration(seconds: s.get<int>('sshKeepAlive')),
      handshakeTimeout: Duration(seconds: s.get<int>('sshConnectTimeout')),
      authTimeout: Duration(seconds: s.get<int>('sshConnectTimeout')),
      onVerifyHostKey: (type, fingerprint) {
        if (policy == 'off') return true;
        final fp = utf8.decode(fingerprint);
        final id = '${c.host}:${c.port}';
        final known = prefs.getString('hostkey:$id');
        if (known != null) {
          if (known == fp) return true;
          log('error', 'SSH: HOST KEY CHANGED for ${c.safeHost}. Connection refused.');
          return false;
        }
        if (policy == 'strict') {
          prefs.setString('hostkey-pending:$id', fp);
          log('error', 'SSH: unknown host key for ${c.safeHost}. Approve it in Settings → SSH → Trusted hosts.');
          return false;
        }
        prefs.setString('hostkey:$id', fp);
        log('info', 'SSH: trusted new host key ($type)${c.locked ? '' : ' $fp'}');
        return true;
      },
    );
  }

  // ───────── lifecycle ─────────

  Future<void> stop() async {
    final c = _client, j = _jump;
    _client = null;
    _jump = null;
    try {
      await _forward?.close();
    } catch (_) {}
    _forward = null;
    c?.close();
    j?.close();
  }

  // ───────── host key store helpers (used by Settings) ─────────

  static Map<String, String> trusted(SharedPreferences p) => {
        for (final k in p.getKeys().where((k) => k.startsWith('hostkey:'))) k.substring(8): p.getString(k) ?? '',
      };

  static Map<String, String> pending(SharedPreferences p) => {
        for (final k in p.getKeys().where((k) => k.startsWith('hostkey-pending:'))) k.substring(16): p.getString(k) ?? '',
      };

  static void approve(SharedPreferences p, String id) {
    final fp = p.getString('hostkey-pending:$id');
    if (fp != null) {
      p.setString('hostkey:$id', fp);
      p.remove('hostkey-pending:$id');
    }
  }

  static void forget(SharedPreferences p, String id) {
    p.remove('hostkey:$id');
    p.remove('hostkey-pending:$id');
  }

  void forgetHostKeys(SharedPreferences prefs) {
    for (final k in prefs.getKeys().where((k) => k.startsWith('hostkey')).toList()) {
      prefs.remove(k);
    }
  }
}
