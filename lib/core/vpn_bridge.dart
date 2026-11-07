import 'package:flutter/services.dart';
import 'dart:convert';

/// One row of a host scan: the value that was tried and how it went.
class ScanResult {
  ScanResult(this.value, this.ok, this.ms, this.error);
  final String value;
  final bool ok;
  final int ms;
  final String error;

  factory ScanResult.fromJson(Map<String, dynamic> j) => ScanResult(
        (j['value'] ?? j['Value'] ?? '').toString(),
        (j['ok'] ?? j['Ok'] ?? false) == true,
        ((j['ms'] ?? j['Ms'] ?? 0) as num).toInt(),
        (j['error'] ?? j['Error'] ?? '').toString(),
      );
}

/// Thin wrapper over the native VPN layer.
/// Android: XRayVpnService (VpnService + the V2-TUN library, v2tun.aar, in-process).
class VpnBridge {
  static const _method = MethodChannel('io.surprise.vpn/core');
  static const _events = EventChannel('io.surprise.vpn/events');

  Stream<Map<String, dynamic>> get events =>
      _events.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map));

  /// Shows the system VPN consent dialog when needed. True when granted.
  Future<bool> prepare() async => (await _method.invokeMethod<bool>('prepare')) ?? false;

  Future<void> start(String configJson, Map<String, dynamic> opts) =>
      _method.invokeMethod('start', {'config': configJson, 'opts': opts});

  Future<void> stop() => _method.invokeMethod('stop');

  Future<String> status() async => (await _method.invokeMethod<String>('status')) ?? 'disconnected';

  // ───────── V2-TUN library calls ─────────

  /// Latency in ms of a request through the given V2-TUN config (the library's own Ping). Throws on failure.
  Future<int> ping(String configJson, {String url = 'http://www.gstatic.com/generate_204'}) async =>
      (await _method.invokeMethod<int>('ping', {'config': configJson, 'url': url})) ?? -1;

  /// Converts a share link with the library's own parser. Returns the V2-TUN config JSON (name under "name").
  Future<String> parseLink(String link) async => (await _method.invokeMethod<String>('parseLink', {'link': link})) ?? '';

  /// Connects to the SSH server in the config (through its payload, TLS and WebSocket chain), does the key exchange
  /// and returns the host key fingerprint ("SHA256:...") without logging in. Throws on failure.
  Future<String> probeHostKey(String configJson, {int timeoutSec = 20}) async =>
      (await _method.invokeMethod<String>('probeHostKey', {'config': configJson, 'timeoutSec': timeoutSec})) ?? '';

  /// Checks a payload template with the library's compiler. Returns the error text, or null when it is valid.
  Future<String?> validatePayload(String template) async {
    try {
      return await _method.invokeMethod<String>('validatePayload', {'template': template});
    } on MissingPluginException {
      return null;
    }
  }

  /// The payload as it will be sent, with visible \r\n and markers where it is split or paused. Throws when invalid.
  Future<String> previewPayload(String template, String host, int port) async =>
      (await _method.invokeMethod<String>('previewPayload', {'template': template, 'host': host, 'port': port})) ?? '';

  /// Names of the library's built-in payload presets ("@connect", "@ssh-ws", ...).
  Future<List<String>> payloadPresets() async {
    try {
      final t = await _method.invokeMethod<String>('payloadPresets') ?? '';
      return t.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } on MissingPluginException {
      return [];
    }
  }

  /// Checks a whole V2-TUN config without connecting (the library's own Validate). Returns the reason the config
  /// is invalid, or null when it is fine.
  Future<String?> validateConfig(String configJson) async {
    try {
      final r = await _method.invokeMethod<String>('validate', {'config': configJson});
      return (r == null || r.isEmpty) ? null : r;
    } on PlatformException catch (e) {
      return e.message ?? 'invalid config';
    } on MissingPluginException {
      return null;
    }
  }

  /// What the payload of a config would send and how the server's reply is checked, without connecting.
  /// Throws when the payload is invalid.
  Future<String> payloadPreviewFor(String configJson) async =>
      (await _method.invokeMethod<String>('payloadPreview', {'config': configJson})) ?? '';

  /// Downloads [url] (empty: the library's default endpoint) through the config for up to [seconds] and returns
  /// (bytes, bits per second). Works with or without a running VPN. Throws on failure.
  Future<(int, double)> speedTest(String configJson, {String url = '', int seconds = 10}) async {
    final t = await _method.invokeMethod<String>('speedTest', {'config': configJson, 'url': url, 'seconds': seconds}) ?? '{}';
    final j = Map<String, dynamic>.from(jsonDecode(t) as Map);
    return (((j['bytes'] ?? 0) as num).toInt(), ((j['bps'] ?? 0) as num).toDouble());
  }

  /// Tries the config once per entry of [values] (one per line) with that entry in [field] (server, tls.sni,
  /// ws.host, payload.host or payload.proxy). A [target] that is a URL is fetched through the tunnel, a host:port
  /// is only dialed. Throws on a bad config or field.
  Future<List<ScanResult>> scanHosts(
    String configJson, {
    required String field,
    required String values,
    required String target,
    int concurrency = 3,
    int seconds = 15,
  }) async {
    final t = await _method.invokeMethod<String>('scanHosts', {
          'config': configJson,
          'field': field,
          'values': values,
          'target': target,
          'concurrency': concurrency,
          'seconds': seconds,
        }) ??
        '[]';
    final raw = jsonDecode(t);
    if (raw is! List) return [];
    return [for (final e in raw) ScanResult.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  /// Dials [target] (host:port) through the config and closes again. Throws when the target cannot be reached.
  Future<void> probe(String configJson, String target) async {
    await _method.invokeMethod('probe', {'config': configJson, 'target': target});
  }

  /// Which config the running tunnel uses: 0 is the main server, 1 the first backup, and so on. -1 when nothing runs.
  Future<int> activeOutbound() async {
    try {
      return (await _method.invokeMethod<int>('activeOutbound')) ?? -1;
    } on MissingPluginException {
      return -1;
    }
  }

  /// How the running tunnel would route a connection: {"action": "proxy|direct|block", "rule": "..."}.
  /// [addr] is host:port. Returns null when the tunnel is not running.
  Future<Map<String, dynamic>?> explainRoute(String addr, {String network = 'tcp', String protocol = ''}) async {
    try {
      final t = await _method.invokeMethod<String>('explainRoute', {'network': network, 'addr': addr, 'protocol': protocol});
      return t == null || t.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(t) as Map);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Swaps the routing section of the running tunnel. Returns an error text, or null on success.
  Future<String?> updateRouting(String routingJson) async {
    try {
      return await _method.invokeMethod<String>('updateRouting', {'routing': routingJson});
    } on MissingPluginException {
      return 'not available on this platform';
    }
  }

  /// Hands downloaded routing lists (list name -> file name in the route list folder) to the running tunnel.
  /// Returns an error text, or null on success.
  Future<String?> applyRouteLists(Map<String, String> files) async {
    try {
      return await _method.invokeMethod<String>('applyRouteLists', {'files': files});
    } on PlatformException catch (e) {
      return e.message ?? 'failed';
    } on MissingPluginException {
      return 'not available on this platform';
    }
  }

  // ───────── platform helpers ─────────

  /// Launchable apps for per-app VPN (Android only).
  Future<List<Map<String, String>>> installedApps() async {
    try {
      final r = await _method.invokeMethod<List<dynamic>>('installedApps') ?? [];
      return r.map((e) => Map<String, String>.from(e as Map)).toList();
    } on PlatformException {
      return [];
    } on MissingPluginException {
      return [];
    }
  }

  /// Text of a deep link / opened file that launched the app (null if none).
  Future<String?> initialLink() async {
    try {
      return await _method.invokeMethod<String>('initialLink');
    } catch (_) {
      return null;
    }
  }

  /// Shows the system "allow unrestricted battery use" prompt (Android).
  Future<void> requestIgnoreBattery() => _method.invokeMethod('requestIgnoreBattery');

  Future<bool> isRooted() async {
    try {
      return await _method.invokeMethod<bool>('isRooted') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Blocks screenshots and the recent-apps thumbnail (Android FLAG_SECURE).
  Future<void> setSecure(bool on) async {
    try {
      await _method.invokeMethod('setSecure', {'on': on});
    } on MissingPluginException {}
  }

  Future<Map<String, dynamic>> diagnostics() async {
    try {
      return Map<String, dynamic>.from(await _method.invokeMethod<Map>('diagnostics') ?? {});
    } on MissingPluginException {
      return {};
    }
  }

  Future<void> openNotificationSettings() => _method.invokeMethod('openNotificationSettings');
  Future<void> openDataSaverSettings() => _method.invokeMethod('openDataSaverSettings');

  Future<void> openSystemVpnSettings() => _method.invokeMethod('openVpnSettings');
  Future<void> openBatterySettings() => _method.invokeMethod('openBatterySettings');
}
