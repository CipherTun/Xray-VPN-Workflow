import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// SSH transport built on DartSSH2: opens an SSH session and exposes a local
/// SOCKS5 proxy (`ssh -D`). Xray-core's `proxy` outbound points at that port,
/// so the TUN device carries all device traffic through the SSH server.
class SshTunnel {
  SSHClient? _client;
  dynamic _forward;

  bool get active => _client != null;

  /// Returns the local SOCKS5 port.
  Future<int> start(
    ServerConfig c,
    AppSettings s,
    SharedPreferences prefs,
    void Function(String level, String msg) log, {
    void Function()? onDropped,
  }) async {
    await stop();
    final port = s.get<int>('socksPort') + 2;
    log('info', 'SSH: connecting to ${c.locked ? 'locked server' : '${c.host}:${c.port}'}');

    final socket = await SSHSocket.connect(c.host, c.port, timeout: const Duration(seconds: 15));

    final pem = c.p('privateKey');
    final client = SSHClient(
      socket,
      username: c.p('user', 'root'),
      identities: pem.isEmpty
          ? null
          : SSHKeyPair.fromPem(pem, c.p('passphrase').isEmpty ? null : c.p('passphrase')),
      onPasswordRequest: () => c.p('id'),
      keepAliveInterval: Duration(seconds: s.get<int>('sshKeepAlive')),
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 15),
      // Trust on first use: remember the fingerprint, reject any change.
      onVerifyHostKey: (type, fingerprint) {
        final fp = utf8.decode(fingerprint);
        final key = 'hostkey:${c.host}:${c.port}';
        final known = prefs.getString(key);
        if (known == null) {
          prefs.setString(key, fp);
          log('info', 'SSH: trusted new host key ($type)${c.locked ? '' : ' $fp'}');
          return true;
        }
        if (known == fp) return true;
        log('error', 'SSH: HOST KEY CHANGED for ${c.safeHost}. Connection refused.');
        return false;
      },
    );
    _client = client;

    await client.authenticated;
    log('info', c.locked ? 'SSH: authenticated' : 'SSH: authenticated as ${c.p('user', 'root')}');

    _forward = await client.forwardDynamic(
      bindHost: '127.0.0.1',
      bindPort: port,
      options: const SSHDynamicForwardOptions(
        handshakeTimeout: Duration(seconds: 10),
        connectTimeout: Duration(seconds: 15),
        maxConnections: 256,
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

  Future<void> stop() async {
    final c = _client;
    _client = null;
    try {
      await _forward?.close();
    } catch (_) {}
    _forward = null;
    c?.close();
  }

  void forgetHostKeys(SharedPreferences prefs) {
    for (final k in prefs.getKeys().where((k) => k.startsWith('hostkey:')).toList()) {
      prefs.remove(k);
    }
  }
}
