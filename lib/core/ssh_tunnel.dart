import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'ssh_payload.dart';

typedef SshLog = void Function(String level, String msg);

/// A plain TCP/TLS socket as an [SSHSocket]. DartSSH2 lets us supply any transport,
/// which is how the TLS-with-custom-SNI and HTTP-payload modes below are implemented.
class _NetSocket implements SSHSocket {
  _NetSocket(this._s, [Stream<Uint8List>? incoming, StreamSink<List<int>>? out])
      : stream = incoming ?? _s,
        _out = out;
  final Socket _s;
  final StreamSink<List<int>>? _out;
  @override
  final Stream<Uint8List> stream;
  @override
  StreamSink<List<int>> get sink => _out ?? _s;
  @override
  Future<void> get done => _s.done;
  @override
  Future<void> close() async => _out != null ? _out.close() : _s.close();
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

  /// HTTP-proxy / payload transport, the way HTTP Injector and HTTP Custom do it: connect to the
  /// proxy (optionally inside TLS), send the payload, accept the reply, then speak SSH over the same
  /// connection. If the reply is a real WebSocket upgrade (Sec-WebSocket-Accept present) the SSH
  /// bytes are carried in WebSocket frames; a bare "101" without it is treated as a raw tunnel.
  Future<SSHSocket> _httpConnect(ServerConfig c, AppSettings s, Duration timeout, SshLog log, bool noDelay) async {
    final proxyHost = c.p('proxyHost', c.host);
    final proxyPort = int.tryParse(c.p('proxyPort')) ?? c.port;
    final pp = PayloadParser.parse(c.p('payload'), c.host, c.port);
    const tlsPorts = {443, 8443, 2053, 2083, 2087, 2096};
    final useTls = pp.sni != null || pp.forceTls || (!pp.forcePlain && tlsPorts.contains(proxyPort));

    Socket sock = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    if (noDelay) sock.setOption(SocketOption.tcpNoDelay, true);
    if (useTls) {
      final sni = pp.sni ?? pp.hostHeader ?? proxyHost;
      sock = await SecureSocket.secure(
        sock,
        host: sni,
        onBadCertificate: (_) => c.p('tlsInsecure') == '1' || s.get<bool>('allowInsecure'),
      ).timeout(timeout);
      log('info', 'SSH: TLS to the proxy established${c.locked ? '' : ' (SNI $sni)'}');
    }

    final ctl = StreamController<Uint8List>();
    final ready = Completer<bool>(); // value: true when the tunnel is WebSocket-framed
    final buf = <int>[];
    final expected = pp.methods.isEmpty ? 1 : pp.methods.length;
    var blocks = 0, skip = 0;
    var passthrough = false, ws = false;
    WsDecoder? decoder;

    int endOfHeaders() {
      for (var i = 0; i + 3 < buf.length; i++) {
        if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) return i;
      }
      return -1;
    }

    void startStream(bool framed) {
      passthrough = true;
      ws = framed;
      if (framed) decoder = WsDecoder(ctl, (frame) => sock.add(frame));
      final rest = Uint8List.fromList(buf);
      buf.clear();
      if (rest.isNotEmpty) framed ? decoder!.add(rest) : ctl.add(rest);
      if (!ready.isCompleted) ready.complete(framed);
    }

    void process() {
      while (!passthrough) {
        if (skip > 0) {
          final n = skip < buf.length ? skip : buf.length;
          buf.removeRange(0, n);
          skip -= n;
          if (skip > 0) return;
          if (blocks >= expected) return startStream(false);
          continue;
        }
        // Some servers answer with the SSH banner straight away, no HTTP at all.
        if (buf.length >= 4 && buf[0] == 0x53 && buf[1] == 0x53 && buf[2] == 0x48 && buf[3] == 0x2D) return startStream(false);
        final i = endOfHeaders();
        if (i < 0) return;
        final head = latin1.decode(buf.sublist(0, i));
        buf.removeRange(0, i + 4);
        final first = head.split('\r\n').first;
        final code = int.tryParse(first.split(' ').skip(1).firstOrNull ?? '') ?? 0;
        if (!first.startsWith('HTTP/')) {
          if (!ready.isCompleted) ready.completeError('Unexpected reply from the proxy');
          return;
        }
        if (!c.locked) log('info', 'SSH: proxy replied $first');
        final method = blocks < pp.methods.length ? pp.methods[blocks] : '';
        blocks++;
        if (code == 101) return startStream(head.toLowerCase().contains('sec-websocket-accept'));
        if (code >= 200 && code < 300) {
          final cl = RegExp(r'content-length:\s*(\d+)', caseSensitive: false).firstMatch(head);
          if (cl != null && method != 'CONNECT') skip = int.parse(cl[1]!);
          if (skip == 0 && blocks >= expected) return startStream(false);
          continue;
        }
        if (!ready.isCompleted) ready.completeError('The proxy answered: $first');
        return;
      }
    }

    sock.listen(
      (d) {
        if (passthrough) {
          ws ? decoder!.add(d) : ctl.add(d);
          return;
        }
        buf.addAll(d);
        process();
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
        if (!ctl.isClosed) ctl.addError(e);
      },
      onDone: () {
        if (!ready.isCompleted) ready.completeError('The proxy closed the connection before the tunnel was open');
        if (!ctl.isClosed) ctl.close();
      },
      cancelOnError: false,
    );

    for (var i = 0; i < pp.parts.length; i++) {
      sock.add(utf8.encode(pp.parts[i].text));
      await sock.flush();
      if (pp.parts[i].delayMs > 0 && i < pp.parts.length - 1) await Future<void>.delayed(Duration(milliseconds: pp.parts[i].delayMs));
    }

    final framed = await ready.future.timeout(timeout);
    log('info', framed ? 'SSH: WebSocket tunnel established' : 'SSH: HTTP proxy tunnel established');
    return _NetSocket(sock, ctl.stream, framed ? WsSink(sock) : null);
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
        // DartSSH2 hands over the OpenSSH-style SHA256 fingerprint (bytes in some releases, text in others).
        final Object raw = fingerprint;
        final fp = raw is String ? raw : utf8.decode(raw as List<int>);
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
