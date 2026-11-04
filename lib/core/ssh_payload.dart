import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// One piece of a payload. Pieces are written one after another with [delayMs] pause after each.
class PayloadPart {
  const PayloadPart(this.text, this.delayMs);
  final String text;
  final int delayMs;
}

class ParsedPayload {
  const ParsedPayload({
    required this.parts,
    required this.methods,
    this.webSocketKeys = const [],
    this.forceTls = false,
    this.forcePlain = false,
    this.sni,
    this.hostHeader,
  });
  final List<PayloadPart> parts;

  /// HTTP method of each request in the payload, in order. One response is expected per entry.
  final List<String> methods;

  /// WebSocket request keys aligned with [methods].
  /// Null means that the corresponding request is not a WebSocket request.
  final List<String?> webSocketKeys;

  final bool forceTls, forcePlain;
  final String? sni;
  final String? hostHeader;
}

/// Understands the payload syntax people know from HTTP Injector / HTTP Custom:
///
///   [host] [port] [host_port] [protocol] [method] [netData]
///   [crlf] [cr] [lf] [lfcr]
///   [split] (250 ms) [delay_split] (1.5 s) [instant_split] (0 ms)
///   [rotate=a;b;c] picks one at random, [ua] random browser User-Agent, [random]
///   [sni=name] wraps the proxy connection in TLS with that SNI, [tls] / [plain] force or forbid TLS
///
/// A header block with `Upgrade: websocket` automatically gets Connection and
/// Sec-WebSocket-Key/Version headers if the payload does not set them.
class PayloadParser {
  static final _rng = Random.secure();
  static const _uas = [
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
    'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0',
  ];

  static const defaultPayload = 'CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf][crlf]';

  static String _sub(String t, String name, String value) =>
      t.replaceAll(RegExp('\\[$name\\]', caseSensitive: false), value);

  static String _randomWord(int n) {
    const abc = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(n, (_) => abc[_rng.nextInt(abc.length)]).join();
  }

  static ParsedPayload parse(String raw, String host, int port) {
    var t = raw.trim().isEmpty ? defaultPayload : raw;

    String? sni;
    t = t.replaceAllMapped(RegExp(r'\[sni=([^\]]+)\]', caseSensitive: false), (m) {
      sni = m[1]!.trim();
      return '';
    });
    final tlsRe = RegExp(r'\[tls\]', caseSensitive: false), plainRe = RegExp(r'\[plain\]', caseSensitive: false);
    final forceTls = tlsRe.hasMatch(t), forcePlain = plainRe.hasMatch(t);
    t = t.replaceAll(tlsRe, '').replaceAll(plainRe, '');

    t = t.replaceAllMapped(RegExp(r'\[rotate=([^\]]+)\]', caseSensitive: false), (m) {
      final options = m[1]!.split(RegExp(r'[;|]'));
      return options[_rng.nextInt(options.length)];
    });
    t = _sub(t, 'ua', _uas[_rng.nextInt(_uas.length)]);
    t = _sub(t, 'random', _randomWord(8));

    t = _sub(t, 'netData', '[method] [host_port] [protocol]');
    t = _sub(t, 'method', 'CONNECT');
    t = _sub(t, 'protocol', 'HTTP/1.1');
    t = _sub(t, 'host_port', '$host:$port');
    t = _sub(t, 'host', host);
    t = _sub(t, 'port', '$port');
    t = _sub(t, 'crlf', '\r\n');
    t = _sub(t, 'lfcr', '\n\r');
    t = _sub(t, 'cr', '\r');
    t = _sub(t, 'lf', '\n');
    t = t.replaceAll(r'\r', '\r').replaceAll(r'\n', '\n');

    // Cut into parts at the split markers.
    final parts = <PayloadPart>[];
    var last = 0;
    for (final m in RegExp(r'\[(instant_split|delay_split|split)\]', caseSensitive: false).allMatches(t)) {
      final kind = m[1]!.toLowerCase();
      parts.add(PayloadPart(t.substring(last, m.start), kind == 'instant_split' ? 0 : (kind == 'delay_split' ? 1500 : 250)));
      last = m.end;
    }
    parts.add(PayloadPart(t.substring(last), 0));

    final fixed = <PayloadPart>[];
    final methods = <String>[];
    final webSocketKeys = <String?>[];
    String? hostHeader;
    for (final p in parts) {
      if (p.text.isEmpty) continue;
      final text = _addWebSocketHeaders(p.text);
      fixed.add(PayloadPart(text, p.delayMs));
      final req = RegExp(r'^\s*([A-Za-z]+)\s+\S+\s+HTTP/\d', caseSensitive: false).firstMatch(text);
      if (req != null) {
        methods.add(req[1]!.toUpperCase());
        final key = RegExp(
          r'^sec-websocket-key:\s*([^\r\n]+)',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(text)?[1]?.trim();
        webSocketKeys.add(key);
      }
      hostHeader ??= RegExp(r'^host:\s*([^\r\n]+)', multiLine: true, caseSensitive: false).firstMatch(text)?[1]?.trim();
    }
    if (hostHeader != null && hostHeader.contains(':') && !hostHeader.contains(']')) {
      hostHeader = hostHeader.split(':').first;
    }
    return ParsedPayload(
      parts: fixed.isEmpty ? [PayloadPart(defaultPayload, 0)] : fixed,
      methods: methods,
      webSocketKeys: webSocketKeys,
      forceTls: forceTls,
      forcePlain: forcePlain,
      sni: sni,
      hostHeader: hostHeader,
    );
  }

  static String _addWebSocketHeaders(String req) {
    final low = req.toLowerCase();
    if (!low.contains('upgrade: websocket')) return req;
    final end = req.indexOf('\r\n\r\n');
    if (end < 0) return req;
    final extra = StringBuffer();
    if (!low.contains('\r\nconnection:')) extra.write('\r\nConnection: Upgrade');
    if (!low.contains('sec-websocket-key')) {
      final key = base64.encode(List.generate(16, (_) => _rng.nextInt(256)));
      extra.write('\r\nSec-WebSocket-Key: $key');
    }
    if (!low.contains('sec-websocket-version')) extra.write('\r\nSec-WebSocket-Version: 13');
    return req.substring(0, end) + extra.toString() + req.substring(end);
  }
}

/// RFC 6455 client-side framing: masked binary frames out, unmasked frames in.
class WsFrames {
  static final _rng = Random.secure();

  static Uint8List encode(List<int> data, {int opcode = 2}) {
    final n = data.length;
    final head = BytesBuilder();
    head.addByte(0x80 | opcode);
    if (n < 126) {
      head.addByte(0x80 | n);
    } else if (n <= 0xFFFF) {
      head.addByte(0x80 | 126);
      head.addByte(n >> 8);
      head.addByte(n & 0xFF);
    } else {
      head.addByte(0x80 | 127);
      for (var i = 7; i >= 0; i--) {
        head.addByte((n >> (8 * i)) & 0xFF);
      }
    }
    final mask = Uint8List.fromList(List.generate(4, (_) => _rng.nextInt(256)));
    head.add(mask);
    final h = head.length;
    final out = Uint8List(h + n)..setRange(0, h, head.toBytes());
    for (var i = 0; i < n; i++) {
      out[h + i] = data[i] ^ mask[i & 3];
    }
    return out;
  }
}

/// Turns incoming WebSocket frames back into the raw byte stream SSH expects.
class WsDecoder {
  WsDecoder(this._out, this._reply);
  final StreamController<Uint8List> _out;
  final void Function(Uint8List frame) _reply;
  Uint8List? _rest;

  void add(Uint8List chunk) {
    final data = _rest == null ? chunk : (BytesBuilder(copy: false)..add(_rest!)..add(chunk)).takeBytes();
    var pos = 0;
    while (data.length - pos >= 2) {
      final b0 = data[pos], b1 = data[pos + 1];
      final opcode = b0 & 0x0F;
      final masked = (b1 & 0x80) != 0;
      var len = b1 & 0x7F;
      var off = 2;
      if (len == 126) {
        if (data.length - pos < 4) break;
        len = (data[pos + 2] << 8) | data[pos + 3];
        off = 4;
      } else if (len == 127) {
        if (data.length - pos < 10) break;
        len = 0;
        for (var i = 0; i < 8; i++) {
          len = (len << 8) | data[pos + 2 + i];
        }
        off = 10;
      }
      final maskAt = pos + off;
      if (masked) off += 4;
      if (data.length - pos < off + len) break;
      var payload = Uint8List.sublistView(data, pos + off, pos + off + len);
      if (masked) {
        final copy = Uint8List.fromList(payload);
        for (var i = 0; i < copy.length; i++) {
          copy[i] ^= data[maskAt + (i & 3)];
        }
        payload = copy;
      }
      pos += off + len;
      switch (opcode) {
        case 0:
        case 1:
        case 2:
          if (!_out.isClosed && payload.isNotEmpty) _out.add(payload);
        case 8:
          if (!_out.isClosed) _out.close();
        case 9:
          _reply(WsFrames.encode(payload, opcode: 10));
      }
    }
    _rest = pos < data.length ? Uint8List.fromList(Uint8List.sublistView(data, pos)) : null;
  }
}

/// Outgoing half: wraps every write in a masked binary frame.
class WsSink implements StreamSink<List<int>> {
  WsSink(this._raw);
  final Socket _raw;

  @override
  void add(List<int> data) {
    const chunk = 16384;
    for (var i = 0; i < data.length; i += chunk) {
      _raw.add(WsFrames.encode(data.sublist(i, min(i + chunk, data.length))));
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _raw.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() {
    try {
      _raw.add(WsFrames.encode(const [], opcode: 8));
    } catch (_) {}
    return _raw.close();
  }

  @override
  Future<void> get done => _raw.done;
}
