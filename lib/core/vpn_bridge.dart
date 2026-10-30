import 'package:flutter/services.dart';

/// Thin wrapper over the native VPN layer.
/// Android: XRayVpnService (VpnService + Xray-core in-process).
/// iOS: NEPacketTunnelProvider extension running Xray-core.
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

  Future<void> openSystemVpnSettings() => _method.invokeMethod('openVpnSettings');
  Future<void> openBatterySettings() => _method.invokeMethod('openBatterySettings');
}
