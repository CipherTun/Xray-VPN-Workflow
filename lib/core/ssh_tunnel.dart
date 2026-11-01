import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

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
  Future<void> flush() => _s.flush();
  @override
  Future<void> close() async => _s.close();
  @override
  void destroy() => _s.destroy();
}


/// Adapts a binary WebSocket message stream to the byte-stream SSHSocket API.
class _WebSocketSshSocket implements SSHSocket {
  _WebSocketSshSocket(this._ws, this.stream, this.done);

  final WebSocket _ws;

  @override
  final Stream<Uint8List> stream;

  @override
  final Future<void> done;

  @override
  StreamSink<List<int>> get sink => _WebSocketSink(_ws);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    await _ws.close();
  }

  @override
  void destroy() {
    _ws.close();
  }
}

class _WebSocketSink implements StreamSink<List<int>> {
  _WebSocketSink(this._ws);

  final WebSocket _ws;

  @override
  void add(List<int> data) => _ws.add(Uint8List.fromList(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _ws.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await _ws.addStream(stream);
  }

  @override
  Future<void> close() async {
    await _ws.close();
  }

  @override
  Future<void> get done async {
    await _ws.done;
  }
}

/// SSH transport built on DartSSH2: opens an SSH session and exposes a local
/// SOCKS5 proxy (`ssh -D`). Xray-core's `proxy` outbound points at that port,
/// so the TUN device carries all device traffic through the SSH server.
///
/// Per-profile transports (profile param `transport`):
///  * `direct`: plain TCP
///  * `tls`: SSH inside TLS
///  * `http`: SSH after an HTTP proxy payload/CONNECT handshake
///  * `ws`: SSH over WebSocket
///  * `wss`: SSH over WebSocket protected by TLS
/// WS/WSS use `path`, `hostHdr`, `wsHeaders`, and optional `sni`.
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

    SSHSocket? pendingSocket;

    try {
      final timeout = Duration(seconds: s.get<int>('sshConnectTimeout'));
      final port = s.get<int>('sshLocalPort') > 0
          ? s.get<int>('sshLocalPort')
          : s.get<int>('socksPort') + 2;

      if (jump != null) {
        log('info', 'SSH: connecting through jump host ${jump.safeHost}');

        final jumpSocket = await _open(jump, s, timeout, log);
        pendingSocket = jumpSocket;

        final jc = await _login(jump, s, prefs, log, jumpSocket);
        pendingSocket = null;
        _jump = jc;

        await jc.authenticated.timeout(timeout);
        log('info', 'SSH: jump host authenticated');

        final targetTransport = c.p('transport', 'direct');
        if (targetTransport == 'ws' || targetTransport == 'wss') {
          pendingSocket = await _open(
            c,
            s,
            timeout,
            log,
            jumpClient: jc,
          );
        } else {
          pendingSocket = await jc.forwardLocal(c.host, c.port);
        }
      } else {
        log(
          'info',
          'SSH: connecting to ${c.locked ? 'locked server' : '${c.host}:${c.port}'} '
          '(${c.p('transport', 'direct')})',
        );
        pendingSocket = await _open(c, s, timeout, log);
      }

      final targetSocket = pendingSocket!;
      final client = await _login(c, s, prefs, log, targetSocket);
      pendingSocket = null;
      _client = client;

      await client.authenticated.timeout(timeout);
      log(
        'info',
        c.locked ? 'SSH: authenticated' : 'SSH: authenticated as ${c.p('user', 'root')}',
      );

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
          unawaited(_handleClientDrop(client, log, onDropped));
        }
      }).catchError((Object e) {
        if (identical(_client, client)) {
          unawaited(_handleClientDrop(client, log, onDropped, error: e));
        }
      });

      return port;
    } catch (_) {
      try {
        await pendingSocket?.close();
      } catch (_) {}

      await stop();
      rethrow;
    }
  }

  // ───────── transports ─────────

  Future<SSHSocket> _open(
    ServerConfig c,
    AppSettings s,
    Duration timeout,
    SshLog log, {
    SSHClient? jumpClient,
  }) async {
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
      case 'ws':
        return _webSocket(c, s, timeout, log, noDelay, secure: false, jumpClient: jumpClient);
      case 'wss':
        return _webSocket(c, s, timeout, log, noDelay, secure: true, jumpClient: jumpClient);
      default:
        final raw = await Socket.connect(c.host, c.port, timeout: timeout);
        if (noDelay) raw.setOption(SocketOption.tcpNoDelay, true);
        return _NetSocket(raw);
    }
  }


  /// Bridges a local TCP connection to a remote TCP connection
  /// carried by an authenticated SSH jump-host channel.
  Future<void> _bridgeJumpSocket(
    Socket local,
    SSHClient jumpClient,
    String remoteHost,
    int remotePort,
  ) async {
    late final SSHForwardChannel channel;

    try {
      channel = await jumpClient.forwardLocal(remoteHost, remotePort);
    } catch (_) {
      local.destroy();
      return;
    }

    var ended = false;

    void closeBoth() {
      if (ended) return;
      ended = true;
      local.destroy();
      unawaited(channel.close());
    }

    local.listen(
      (data) {
        if (!ended) channel.sink.add(data);
      },
      onError: (Object error, StackTrace stack) {
        closeBoth();
      },
      onDone: closeBoth,
      cancelOnError: true,
    );

    channel.stream.listen(
      (data) {
        if (!ended) {
          try {
            local.add(data);
          } catch (_) {
            closeBoth();
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        closeBoth();
      },
      onDone: closeBoth,
      cancelOnError: true,
    );
  }

  /// Opens SSH over a WebSocket connection. Dart's WebSocket implementation
  /// performs the RFC 6455 handshake, masking, frame parsing, ping/pong and
  /// close handling. Binary WebSocket messages carry the SSH byte stream.
  Future<SSHSocket> _webSocket(
    ServerConfig c,
    AppSettings s,
    Duration timeout,
    SshLog log,
    bool noDelay, {
    required bool secure,
    SSHClient? jumpClient,
  }) async {
    final endpointHost = c.p('proxyHost', c.host).trim();
    final endpointPort = int.tryParse(c.p('proxyPort')) ??
        (secure ? (c.port == 80 ? 443 : c.port) : c.port);

    if (endpointHost.isEmpty || endpointPort < 1 || endpointPort > 65535) {
      throw ArgumentError('Invalid SSH WebSocket endpoint.');
    }

    final sni = c.p('sni', c.host).trim();
    final urlHost = secure ? sni : c.host;
    if (urlHost.isEmpty) {
      throw ArgumentError('WebSocket hostname cannot be empty.');
    }

    final configuredPath = c.p('path', '/').trim();
    final wsPath = configuredPath.isEmpty
        ? '/'
        : (configuredPath.startsWith('/')
            ? configuredPath
            : '/$configuredPath');

    final uri = Uri(
      scheme: secure ? 'wss' : 'ws',
      host: urlHost,
      port: endpointPort,
      path: wsPath,
    );

    final headers = <String, dynamic>{};
    final hostHeader = c.p('hostHdr', c.host).trim();
    if (hostHeader.isNotEmpty) {
      headers['Host'] = hostHeader;
    }

    for (final line in const LineSplitter().convert(c.p('wsHeaders'))) {
      if (line.trim().isEmpty) continue;

      final index = line.indexOf(':');
      if (index <= 0) {
        throw FormatException('Invalid WebSocket header: $line');
      }

      final name = line.substring(0, index).trim();
      final value = line.substring(index + 1).trim();
      final lower = name.toLowerCase();

      if (name.isEmpty ||
          lower == 'host' ||
          lower == 'upgrade' ||
          lower == 'connection' ||
          lower == 'sec-websocket-key' ||
          lower == 'sec-websocket-protocol' ||
          lower == 'sec-websocket-version' ||
          lower == 'content-length' ||
          lower == 'transfer-encoding') {
        throw FormatException('Reserved WebSocket header: $name');
      }

      headers[name] = value;
    }

    ServerSocket? jumpBridge;
    if (jumpClient != null) {
      jumpBridge = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );

      final activeBridge = jumpBridge;
      activeBridge.listen((localSocket) {
        unawaited(
          _bridgeJumpSocket(
            localSocket,
            jumpClient,
            endpointHost,
            endpointPort,
          ),
        );
      });
    }

    final httpClient = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT'
      ..badCertificateCallback = (_, __, ___) =>
          secure &&
          (c.p('tlsInsecure') == '1' || s.get<bool>('allowInsecure'));

    // The URL retains the target hostname for Host/SNI/certificate checks.
    // With a jump host, the actual TCP connection goes to the loopback
    // listener, which forwards it through an SSHForwardChannel.
    httpClient.connectionFactory = (requestedUri, proxyHost, proxyPort) {
      if (proxyHost != null || proxyPort != null) {
        throw UnsupportedError(
          'Unexpected HTTP proxy configured for SSH WebSocket.',
        );
      }

      final socketFuture = Socket.connect(
        jumpBridge?.address ?? InternetAddress.loopbackIPv4,
        jumpBridge?.port ?? endpointPort,
        timeout: timeout,
      ).then((socket) {
        if (noDelay) {
          socket.setOption(SocketOption.tcpNoDelay, true);
        }
        return socket;
      });

      return Future<ConnectionTask<Socket>>.value(
        ConnectionTask<Socket>.fromSocket(socketFuture, () {}),
      );
    };

    late final WebSocket ws;
    try {
      ws = await WebSocket.connect(
        uri.toString(),
        customClient: httpClient,
        headers: headers,
        compression: CompressionOptions.compressionOff,
      ).timeout(timeout);

      await jumpBridge?.close();
      httpClient.close(force: false);
    } catch (_) {
      await jumpBridge?.close();
      httpClient.close(force: true);
      rethrow;
    }

    final incoming = StreamController<Uint8List>();
    final done = Completer<void>();
    var closed = false;

    void closeInput([Object? error, StackTrace? stack]) {
      if (closed) return;
      closed = true;

      if (error != null) {
        incoming.addError(error, stack);
      }

      incoming.close();
      if (!done.isCompleted) done.complete();
    }

    ws.listen(
      (event) {
        if (event is List<int>) {
          incoming.add(Uint8List.fromList(event));
        } else if (event is String) {
          closeInput(
            const FormatException(
              'WebSocket server sent a text frame; binary SSH data is required.',
            ),
          );
        }
      },
      onError: (Object error, StackTrace stack) {
        closeInput(error, stack);
      },
      onDone: closeInput,
      cancelOnError: true,
    );

    log(
      'info',
      'SSH: ${secure ? 'WSS' : 'WS'} connected; '
      'endpoint $endpointHost:$endpointPort, path $wsPath'
      '${secure ? ', SNI $sni' : ''}',
    );

    return _WebSocketSshSocket(ws, incoming.stream, done.future);
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
        if (first.startsWith('HTTP/') && (first.contains(' 200'))) {
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

  Future<void> _handleClientDrop(
    SSHClient client,
    SshLog log,
    void Function()? onDropped, {
    Object? error,
  }) async {
    if (!identical(_client, client)) return;

    final forward = _forward;
    final jump = _jump;
    _client = null;
    _jump = null;
    _forward = null;

    try {
      await forward?.close();
    } catch (e) {
      log('warn', 'SSH: SOCKS cleanup failed: $e');
    }

    try {
      await client.close();
    } catch (_) {}

    try {
      await jump?.close();
    } catch (_) {}

    if (error == null) {
      log('warn', 'SSH: session closed');
    } else {
      log('error', 'SSH: $error');
    }
    onDropped?.call();
  }

  Future<void> stop() async {
    final client = _client;
    final jump = _jump;
    final forward = _forward;

    _client = null;
    _jump = null;
    _forward = null;

    try {
      await forward?.close();
    } catch (_) {}

    try {
      await client?.close();
    } catch (_) {}

    try {
      await jump?.close();
    } catch (_) {}
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
