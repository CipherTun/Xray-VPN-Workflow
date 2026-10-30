import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cryptography/cryptography.dart';

import '../core/accents.dart';
import '../core/config_package.dart';
import '../core/link_parser.dart';
import '../core/models.dart';
import '../core/ssh_tunnel.dart';
import '../core/vpn_bridge.dart';
import '../core/xray_config.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

class AppState extends ChangeNotifier {
  AppState._(this.prefs);

  static Future<AppState> create() async {
    final s = AppState._(await SharedPreferences.getInstance());
    s._load();
    s._listen();
    return s;
  }

  final SharedPreferences prefs;
  final bridge = VpnBridge();
  final ssh = SshTunnel();

  AppSettings settings = AppSettings();
  List<ServerConfig> configs = [];
  String? selectedId;

  VpnStatus status = VpnStatus.disconnected;
  String? lastError;
  final List<LogEntry> logs = [];
  DateTime? connectedAt;
  int rxBps = 0, txBps = 0, rxTotal = 0, txTotal = 0;
  final List<double> rxHistory = List<double>.filled(48, 0, growable: true);

  // Device binding, shared-config helpers, usage history, app lock
  late String deviceId;
  String get deviceCode {
    final d = deviceId.toUpperCase();
    return '${d.substring(0, 4)}-${d.substring(4, 8)}-${d.substring(8, 12)}';
  }

  Map<String, List<int>> usage = {}; // yyyy-mm-dd -> [rx, tx]
  List<Map<String, dynamic>> subs = [];
  String? pendingImport;
  bool appLocked = false;
  bool capExceeded = false;
  DateTime? sleepAt;
  DateTime? _bgAt;
  int _usageTicks = 0;

  Timer? _timeout, _ticker, _retryTimer;
  bool _userStopped = true;
  int _retries = 0;

  // ───────── persistence ─────────
  void _load() {
    final rnd = Random.secure();
    deviceId = prefs.getString('deviceId') ??
        List.generate(12, (_) => rnd.nextInt(16).toRadixString(16)).join();
    prefs.setString('deviceId', deviceId);
    try {
      final u = prefs.getString('usage');
      if (u != null) {
        usage = (jsonDecode(u) as Map).map((k, v) => MapEntry(k as String, (v as List).cast<int>()));
      }
      subs = (jsonDecode(prefs.getString('subs') ?? '[]') as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {}
    try {
      final s = prefs.getString('settings');
      if (s != null) settings = AppSettings(jsonDecode(s) as Map<String, dynamic>);
      final c = prefs.getString('configs');
      if (c != null) {
        configs = (jsonDecode(c) as List).map((e) => ServerConfig.fromJson(e as Map<String, dynamic>)).toList();
      }
      selectedId = prefs.getString('selected');
      if (selectedId == null && configs.isNotEmpty) selectedId = configs.first.id;
      appLocked = settings.get<String>('pin').isNotEmpty;
    } catch (e) {
      log('error', 'Could not load saved data: $e');
    }
  }

  void _save() {
    prefs.setString('settings', jsonEncode(settings.toJson()));
    prefs.setString('configs', jsonEncode(configs.map((c) => c.toJson()).toList()));
    if (selectedId != null) prefs.setString('selected', selectedId!);
    prefs.setString('subs', jsonEncode(subs));
  }

  void _saveUsage() => prefs.setString('usage', jsonEncode(usage));

  // ───────── theme ─────────
  ThemeMode get themeMode => switch (settings.get<int>('themeMode')) {
        0 => ThemeMode.system,
        1 => ThemeMode.light,
        _ => ThemeMode.dark,
      };

  Color get accentRaw {
    final i = settings.get<int>('accent');
    return i == Accents.customIndex
        ? Color(settings.get<int>('customAccent'))
        : Accents.presets[i.clamp(0, Accents.presets.length - 1)].color;
  }

  /// Very dark accents (the "Black" preset) are lifted in dark mode so they stay visible.
  Color accentFor(Brightness b) {
    final c = accentRaw;
    if (b == Brightness.dark && c.computeLuminance() < 0.12) {
      return Color.lerp(c, Colors.white, 0.62)!;
    }
    if (b == Brightness.light && c.computeLuminance() > 0.85) {
      return Color.lerp(c, Colors.black, 0.4)!;
    }
    return c;
  }

  void setSetting(String key, dynamic value) {
    settings.set(key, value);
    _save();
    notifyListeners();
  }

  void resetSettings() {
    settings = AppSettings();
    _save();
    notifyListeners();
  }

  // ───────── logs ─────────
  void log(String level, String msg) {
    final s = selected;
    if (s != null && s.locked && s.host.isNotEmpty) msg = msg.replaceAll(s.host, '•••');
    logs.add(LogEntry(level, msg));
    if (logs.length > 1500) logs.removeRange(0, 300);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  // ───────── configs ─────────
  ServerConfig? get selected => configs.where((c) => c.id == selectedId).firstOrNull;

  void select(String id) {
    selectedId = id;
    _save();
    notifyListeners();
  }

  void upsert(ServerConfig c) {
    final i = configs.indexWhere((e) => e.id == c.id);
    if (i >= 0) {
      configs[i] = c;
    } else {
      configs.add(c);
      selectedId ??= c.id;
    }
    _save();
    notifyListeners();
  }

  void remove(String id) {
    configs.removeWhere((c) => c.id == id);
    if (selectedId == id) selectedId = configs.firstOrNull?.id;
    _save();
    notifyListeners();
  }

  void toggleFavorite(ServerConfig c) {
    c.favorite = !c.favorite;
    _save();
    notifyListeners();
  }

  /// Imports share links or a subscription payload. Returns how many were added.
  int importText(String text) {
    final list = LinkParser.parseMany(text);
    for (final c in list) {
      configs.add(c);
    }
    if (list.isNotEmpty) selectedId ??= list.first.id;
    _save();
    notifyListeners();
    log('info', 'Imported ${list.length} profile(s)');
    return list.length;
  }

  Future<String> _download(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'XRayVPN/1.0');
      final res = await req.close();
      if (res.statusCode >= 400) throw 'HTTP ${res.statusCode}';
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  static String _subGroup(String url) => 'sub:${url.hashCode.toRadixString(36)}';

  Future<int> importSubscription(String url) async {
    final fresh = LinkParser.parseMany(await _download(url));
    final g = _subGroup(url);
    configs.removeWhere((c) => c.group == g);
    for (final c in fresh) {
      c.group = g;
      configs.add(c);
    }
    if (fresh.isNotEmpty) selectedId ??= fresh.first.id;
    subs.removeWhere((e) => e['url'] == url);
    subs.add({'url': url, 'updated': DateTime.now().toUtc().toIso8601String()});
    _save();
    notifyListeners();
    log('info', 'Subscription added: ${fresh.length} profile(s)');
    return fresh.length;
  }

  /// Re-downloads subscriptions that are older than the refresh interval (or all when [force]).
  Future<int> refreshSubscriptions({bool force = false}) async {
    var total = 0;
    for (final sub in subs) {
      final url = sub['url'] as String;
      final last = DateTime.tryParse(sub['updated'] as String? ?? '');
      if (!force && last != null && DateTime.now().toUtc().difference(last).inHours < settings.get<int>('subRefreshHours')) continue;
      try {
        final fresh = LinkParser.parseMany(await _download(url));
        if (fresh.isEmpty) continue;
        final g = _subGroup(url);
        final old = configs.where((c) => c.group == g).toList();
        final selName = selected?.group == g ? selected?.name : null;
        configs.removeWhere((c) => c.group == g);
        for (final c in fresh) {
          c.group = g;
          c.favorite = old.where((o) => o.name == c.name).firstOrNull?.favorite ?? false;
          configs.add(c);
        }
        if (selName != null) selectedId = configs.where((c) => c.name == selName).firstOrNull?.id;
        sub['updated'] = DateTime.now().toUtc().toIso8601String();
        total += fresh.length;
      } catch (e) {
        log('warn', 'Subscription refresh failed: $e');
      }
    }
    if (selected == null) selectedId = configs.firstOrNull?.id;
    _save();
    notifyListeners();
    return total;
  }

  /// Imports an already decoded share package (expiry / device checks happen inside).
  Future<List<ServerConfig>> importPackage(ConfigPackage pkg) async {
    final list = await pkg.prepareImport(deviceId);
    configs.addAll(list);
    selectedId = list.first.id;
    _save();
    notifyListeners();
    log('info', 'Imported ${list.length} profile(s) from a shared config');
    return list;
  }

  Future<void> pingOne(ServerConfig c) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(c.host, c.port, timeout: const Duration(seconds: 4));
      sw.stop();
      s.destroy();
      c.pingMs = sw.elapsedMilliseconds;
    } catch (_) {
      c.pingMs = -1;
    }
    notifyListeners();
  }

  Future<void> pingAll() async {
    await Future.wait(configs.map(pingOne));
    _save();
  }

  // ───────── connection ─────────
  bool get isOn => status == VpnStatus.connected;
  bool get isBusy => status == VpnStatus.connecting || status == VpnStatus.disconnecting;

  Duration get uptime => connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);

  Future<void> toggle() async {
    if (isBusy) return;
    if (status == VpnStatus.connected) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> connect() async {
    if (settings.get<bool>('smartConnect') && configs.length > 1 && !isOn) {
      await pingAll();
      final ok = configs.where((e) => !e.expired && (e.pingMs ?? -1) >= 0).toList()..sort((a, b) => a.pingMs!.compareTo(b.pingMs!));
      if (ok.isNotEmpty) {
        selectedId = ok.first.id;
        log('info', 'Smart connect picked "${ok.first.name}" (${ok.first.pingMs} ms)');
      }
    }
    final c = selected;
    if (c != null && c.expired) {
      lastError = 'This config has expired. Ask the sender for a new one.';
      log('error', lastError!);
      _setStatus(VpnStatus.error);
      return;
    }
    if (c != null && c.deviceHash != null && c.deviceHash != await ConfigPackage.hashDeviceId(deviceId)) {
      lastError = 'This config is locked to a different device.';
      log('error', lastError!);
      _setStatus(VpnStatus.error);
      return;
    }
    if (c == null) {
      lastError = 'Add a server in Configs first.';
      log('warn', lastError!);
      notifyListeners();
      return;
    }
    _userStopped = false;
    _retryTimer?.cancel();
    _setStatus(VpnStatus.connecting);
    if (settings.get<bool>('haptics')) HapticFeedback.mediumImpact();

    try {
      if (Platform.isAndroid) await Permission.notification.request();
      if (!await bridge.prepare()) {
        throw 'VPN permission was not granted.';
      }
      int? sshPort;
      if (c.proto == Proto.ssh) {
        sshPort = await ssh.start(c, settings, prefs, log, onDropped: _onSshDropped);
      }
      final cfg = buildXrayConfig(c, settings, sshSocksPort: sshPort);
      await bridge.start(jsonEncode(cfg), {
        'name': c.name,
        'killSwitch': settings.get<bool>('killSwitch'),
        'ipv6': settings.get<bool>('ipv6'),
        'mtu': settings.get<int>('mtu'),
        'dns': dnsServersFor(settings),
        'perAppMode': settings.get<String>('perAppMode'),
        'perApps': settings.list('perApps'),
        'logLevel': settings.get<String>('logLevel'),
        'wakeMode': settings.get<String>('wakeMode'),
        'bootStart': settings.get<bool>('bootStart'),
      });
      final mins = settings.get<int>('sleepTimer');
      sleepAt = mins > 0 ? DateTime.now().add(Duration(minutes: mins)) : null;
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 25), () {
        if (status == VpnStatus.connecting) _fail('Connection timed out.');
      });
    } catch (e) {
      _fail(e.toString());
    }
  }

  Future<void> disconnect() async {
    _userStopped = true;
    _retryTimer?.cancel();
    _timeout?.cancel();
    _setStatus(VpnStatus.disconnecting);
    try {
      await bridge.stop();
    } catch (e) {
      log('error', 'Stop failed: $e');
    }
    await ssh.stop();
    _setStatus(VpnStatus.disconnected);
  }

  void _fail(String msg) {
    lastError = msg;
    log('error', msg);
    bridge.stop().catchError((_) {});
    ssh.stop();
    _setStatus(VpnStatus.error);
  }

  void _onSshDropped() {
    if (_userStopped) return;
    log('warn', 'SSH session dropped');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_userStopped || !settings.get<bool>('autoReconnect') || _retries >= 5) return;
    _retries++;
    final delay = Duration(seconds: 2 * _retries);
    log('info', 'Reconnecting in ${delay.inSeconds}s (attempt $_retries/5)');
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () async {
      await bridge.stop().catchError((_) {});
      await connect();
    });
  }

  void _setStatus(VpnStatus s) {
    status = s;
    if (s == VpnStatus.connected) {
      connectedAt ??= DateTime.now();
      _retries = 0;
      lastError = null;
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else if (s == VpnStatus.disconnected || s == VpnStatus.error) {
      connectedAt = null;
      rxBps = txBps = 0;
      rxTotal = txTotal = 0;
      _saveUsage();
      _ticker?.cancel();
    }
    notifyListeners();
  }

  void _tick() {
    final c = selected;
    if (c != null && c.expired) {
      lastError = 'This config has expired.';
      log('warn', '"${c.name}" has expired. Disconnecting.');
      disconnect();
      return;
    }
    if (sleepAt != null && DateTime.now().isAfter(sleepAt!)) {
      sleepAt = null;
      log('info', 'Sleep timer finished. Disconnecting.');
      disconnect();
      return;
    }
    notifyListeners();
  }

  // ───────── usage history ─────────
  static String dayKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  List<int> get today => usage[dayKey(DateTime.now())] ?? [0, 0];

  void _addUsage(int rx, int tx) {
    if (rx <= 0 && tx <= 0) return;
    final e = usage.putIfAbsent(dayKey(DateTime.now()), () => [0, 0]);
    e[0] += rx < 0 ? 0 : rx;
    e[1] += tx < 0 ? 0 : tx;
    if (usage.length > 90) usage.remove((usage.keys.toList()..sort()).first);
    final cap = settings.get<int>('dailyCapMb');
    if (cap > 0 && (e[0] + e[1]) > cap * 1024 * 1024 && !capExceeded) {
      capExceeded = true;
      log('warn', 'Daily data limit of $cap MB reached');
    }
    if (++_usageTicks % 15 == 0) _saveUsage();
  }

  void clearUsage() {
    usage.clear();
    capExceeded = false;
    _saveUsage();
    notifyListeners();
  }

  // ───────── app lock (PIN) ─────────
  Future<String> _pinHash(String pin, String salt) async =>
      base64.encode((await Sha256().hash(utf8.encode('$salt|$pin'))).bytes);

  Future<void> setPin(String pin) async {
    if (pin.isEmpty) {
      setSetting('pin', '');
      appLocked = false;
    } else {
      final r = Random.secure();
      final salt = base64.encode(List.generate(8, (_) => r.nextInt(256)));
      setSetting('pin', '$salt:${await _pinHash(pin, salt)}');
    }
    notifyListeners();
  }

  Future<bool> unlock(String pin) async {
    final parts = settings.get<String>('pin').split(':');
    if (parts.length != 2) {
      appLocked = false;
      notifyListeners();
      return true;
    }
    final ok = await _pinHash(pin, parts[0]) == parts[1];
    if (ok) {
      appLocked = false;
      notifyListeners();
    }
    return ok;
  }

  /// Lock again if the app was in the background for more than 30 seconds.
  void onLifecycle(AppLifecycleState st) {
    if (st == AppLifecycleState.paused) _bgAt = DateTime.now();
    if (st == AppLifecycleState.resumed && _bgAt != null) {
      if (settings.get<String>('pin').isNotEmpty && DateTime.now().difference(_bgAt!).inSeconds > 30) {
        appLocked = true;
        notifyListeners();
      }
      _bgAt = null;
    }
  }

  void clearPendingImport() => pendingImport = null;

  void _listen() {
    bridge.events.listen(_onEvent, onError: (Object e) => log('error', 'Bridge: $e'));
    bridge.initialLink().then((t) {
      if (t != null && t.isNotEmpty) {
        pendingImport = t;
        notifyListeners();
      }
    });
    bridge.status().then((s) {
      if (s == 'connected') _setStatus(VpnStatus.connected);
    }).catchError((_) {});
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'status':
        final st = e['state'] as String;
        final msg = e['message'] as String?;
        if (st == 'connected') {
          _timeout?.cancel();
          _setStatus(VpnStatus.connected);
          log('info', 'Tunnel is up');
        } else if (st == 'connecting') {
          if (status != VpnStatus.connecting) _setStatus(VpnStatus.connecting);
        } else if (st == 'error') {
          _fail(msg ?? 'The tunnel stopped unexpectedly.');
          _scheduleReconnect();
        } else if (st == 'revoked') {
          // The user switched the VPN off from system settings or another VPN took over.
          _userStopped = true;
          ssh.stop();
          log('warn', 'VPN was turned off by the system or another VPN app');
          _setStatus(VpnStatus.disconnected);
        } else if (st == 'disconnected') {
          if (!_userStopped && status == VpnStatus.connected) {
            log('warn', 'Tunnel dropped');
            _setStatus(VpnStatus.disconnected);
            _scheduleReconnect();
          } else if (status != VpnStatus.connecting) {
            _setStatus(VpnStatus.disconnected);
          }
        }
      case 'import':
        pendingImport = e['text'] as String?;
        notifyListeners();
      case 'log':
        log(e['level'] as String? ?? 'info', e['msg'] as String? ?? '');
      case 'stats':
        rxBps = (e['rxBps'] as num?)?.toInt() ?? 0;
        txBps = (e['txBps'] as num?)?.toInt() ?? 0;
        final nrx = (e['rx'] as num?)?.toInt() ?? rxTotal;
        final ntx = (e['tx'] as num?)?.toInt() ?? txTotal;
        _addUsage(nrx >= rxTotal ? nrx - rxTotal : nrx, ntx >= txTotal ? ntx - txTotal : ntx);
        rxTotal = nrx;
        txTotal = ntx;
        rxHistory
          ..removeAt(0)
          ..add(rxBps.toDouble());
        notifyListeners();
    }
  }

  Future<void> onAppStart() async {
    refreshSubscriptions();
    if (settings.get<bool>('autoConnect') && selected != null && status == VpnStatus.disconnected) {
      await connect();
    }
  }

  /// HttpClient that goes through the tunnel (the app itself bypasses the VPN).
  HttpClient tunnelClient() {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (isOn) {
      final port = settings.get<int>('socksPort') + 1;
      c.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    }
    return c;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _timeout?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }
}
