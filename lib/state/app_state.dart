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
import '../core/route_lists.dart';
import '../core/v2tun_config.dart';
import '../core/vpn_bridge.dart';

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

  Timer? _timeout, _ticker, _retryTimer, _routingTimer;
  bool _userStopped = true;
  int _retries = 0;

  /// Settings that change the routing section of the tunnel. While connected they are applied live.
  static const _routingKeys = {
    'routing', 'bypassCountry', 'domainStrategy', 'blockQuic', 'blockBittorrent', 'customRules', 'listAdsUrl', 'listDirectUrl', 'listIpBase',
  };

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
    if (key == 'secureScreen') applySecure();
    if (isOn && _routingKeys.contains(key)) _scheduleRoutingUpdate();
    notifyListeners();
  }

  /// Block screenshots when the user asked for it, or when the selected config demands it.
  void applySecure() {
    bridge.setSecure(settings.get<bool>('secureScreen') || (selected?.secure ?? false));
  }

  /// Settings as JSON text (no servers, no PIN hash) for backup or moving to another phone.
  String exportSettings() {
    final m = Map<String, dynamic>.from(settings.toJson())..remove('pin');
    return const JsonEncoder.withIndent('  ').convert(m);
  }

  /// Merges exported settings over the current ones. Unknown keys are ignored.
  int importSettings(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    var n = 0;
    j.forEach((k, v) {
      if (k == 'pin' || !AppSettings.defaults.containsKey(k)) return;
      final d = AppSettings.defaults[k];
      if (d is List) {
        settings.set(k, (v as List).cast<String>());
      } else if (d is double) {
        settings.set(k, (v as num).toDouble());
      } else if (d.runtimeType == v.runtimeType) {
        settings.set(k, v);
      } else {
        return;
      }
      n++;
    });
    _save();
    applySecure();
    notifyListeners();
    return n;
  }

  /// Removes servers, settings, usage, downloaded route lists and the PIN. Cannot be undone.
  Future<void> wipeAll() async {
    if (status != VpnStatus.disconnected) await disconnect();
    await prefs.clear();
    try {
      final d = await RouteLists.dir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
    configs = [];
    selectedId = null;
    settings = AppSettings();
    usage.clear();
    logs.clear();
    appLocked = false;
    final rnd = Random.secure();
    deviceId = List.generate(12, (_) => rnd.nextInt(16).toRadixString(16)).join();
    prefs.setString('deviceId', deviceId);
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
    applySecure();
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
    final ids = settings.list('failoverIds');
    if (ids.contains(id)) settings.set('failoverIds', ids.where((x) => x != id).toList());
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
          final prev = old.where((o) => o.name == c.name).firstOrNull;
          c.favorite = prev?.favorite ?? false;
          // Keep the SSH host key that was pinned on first use when the server is the same.
          if (prev != null && prev.host == c.host && prev.port == c.port && c.p('hostKey').isEmpty && prev.p('hostKey').isNotEmpty) {
            c.params['hostKey'] = prev.p('hostKey');
          }
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

  // ───────── V2-TUN config ─────────

  /// The V2-TUN JSON config of a profile. [forPing] leaves routing out (a latency test always goes through the
  /// server). [quiet] drops the build warnings (used for background latency tests).
  Map<String, dynamic> configFor(ServerConfig c, {bool forPing = false, bool quiet = false}) =>
      buildV2tunConfig(c, settings, forPing: forPing, onWarn: quiet ? null : (m) => log('warn', m));

  /// Servers tried after [c] when failover is on (the library's `backups`, in the order they were picked).
  List<ServerConfig> _backupProfiles(ServerConfig c) {
    if (settings.get<String>('failoverMode') != 'ordered') return const [];
    return [
      for (final id in settings.list('failoverIds'))
        if (_byId(id) case final b? when b.id != c.id && !b.expired) b,
    ];
  }

  /// Primary config plus, in failover mode, the chosen extra servers as ordered `backups`.
  Map<String, dynamic> _tunnelConfig(ServerConfig c, List<ServerConfig> backups) {
    final cfg = buildV2tunConfig(c, settings, backups: backups, onWarn: (m) => log('warn', m));
    final n = (cfg['backups'] as List?)?.length ?? 0;
    if (n > 0) log('info', 'Failover: $n backup server(s) after "${c.name}"');
    return cfg;
  }

  /// Trust on first use for SSH: a profile without a pinned host key gets the key the server shows now, and
  /// the library refuses any different key from then on. When the key cannot be read the connection goes ahead
  /// unpinned (and says so in the log) rather than failing for a reason unrelated to the user's settings.
  Future<void> _pinHostKeys(Iterable<ServerConfig> profiles) async {
    var changed = false;
    for (final c in profiles) {
      if (c.proto != Proto.ssh || c.p('hostKey').isNotEmpty) continue;
      try {
        final probe = buildV2tunConfig(c, settings, forPing: true);
        final fp = await bridge.probeHostKey(jsonEncode(probe), timeoutSec: settings.get<int>('connectTimeout'));
        if (fp.isEmpty) continue;
        c.params['hostKey'] = fp;
        changed = true;
        log('info', 'SSH host key of "${c.name}" pinned on first use: $fp');
      } catch (e) {
        log('warn', 'Could not read the SSH host key of "${c.name}" ($e). Connecting without pinning it.');
      }
    }
    if (changed) {
      _save();
      notifyListeners();
    }
  }

  /// Makes sure the lists the routing settings need are on disk. Returns list name -> file name.
  Future<Map<String, String>> _prepareLists({bool force = false}) async {
    final sources = routeListSources(settings);
    if (sources.isEmpty) return {};
    return RouteLists.prepare(sources, force: force, maxAgeDays: settings.get<int>('listRefreshDays'), log: log);
  }

  /// Re-downloads every list the current routing settings use, and applies them when connected.
  Future<void> refreshRouteLists() async {
    final lists = await _prepareLists(force: true);
    if (isOn && lists.isNotEmpty) {
      final err = await bridge.applyRouteLists(lists);
      if (err != null) log('warn', 'Route lists: $err');
    }
    notifyListeners();
  }

  void _scheduleRoutingUpdate() {
    _routingTimer?.cancel();
    _routingTimer = Timer(const Duration(milliseconds: 700), applyRoutingLive);
  }

  /// Applies the current routing settings to the running tunnel without reconnecting: the new rules first, then
  /// the lists they need (a new country, for example, has to be downloaded).
  Future<void> applyRoutingLive() async {
    if (!isOn) return;
    try {
      final err = await bridge.updateRouting(jsonEncode(buildRouting(settings, onWarn: (m) => log('warn', m))));
      if (err != null) {
        log('warn', 'Routing could not be changed while connected ($err). It applies the next time you connect.');
        return;
      }
      final lists = await _prepareLists();
      if (lists.isNotEmpty) {
        final e2 = await bridge.applyRouteLists(lists);
        if (e2 != null) log('warn', 'Route lists: $e2');
      }
      log('info', 'Routing updated');
    } catch (e) {
      log('warn', 'Routing update failed: $e');
    }
  }

  /// How the running tunnel routes [host] ("example.com" or "example.com:443"), as text. Null when not connected.
  Future<String?> explainRoute(String host, {String protocol = ''}) async {
    final addr = host.contains(':') && !host.contains(']') && host.split(':').length == 2 ? host : '$host:443';
    final r = await bridge.explainRoute(addr, protocol: protocol);
    if (r == null) return null;
    final rule = (r['rule'] as String?) ?? '';
    return '${(r['action'] as String? ?? '?').toUpperCase()}${rule.isEmpty ? '' : ' · $rule'}';
  }

  // ───────── latency ─────────

  /// Real latency: a request through the library with this profile, so it also proves the credentials work.
  Future<void> pingOne(ServerConfig c) async {
    try {
      c.pingMs = await bridge.ping(jsonEncode(configFor(c, forPing: true, quiet: true)));
    } catch (_) {
      c.pingMs = -1;
    }
    notifyListeners();
  }

  Future<void> pingAll() async {
    // A few at a time: every test builds a full tunnel client (an SSH profile does a whole handshake).
    for (var i = 0; i < configs.length; i += 6) {
      await Future.wait(configs.skip(i).take(6).toList().map(pingOne));
    }
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
    if (c.dataLimitReached) {
      lastError = 'The data limit of this config has been used up.';
      log('error', lastError!);
      _setStatus(VpnStatus.error);
      return;
    }
    if (c.blockRooted && await bridge.isRooted()) {
      lastError = 'This config cannot be used on a rooted device.';
      log('error', lastError!);
      _setStatus(VpnStatus.error);
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
      final backups = _backupProfiles(c);
      // Before the tunnel is up, so the key probe and the list downloads do not depend on the VPN.
      await _pinHostKeys([c, ...backups]);
      // Throws V2tunConfigError for settings the library cannot honour (shown to the person as is).
      final cfg = _tunnelConfig(c, backups);
      final lists = await _prepareLists();
      await bridge.start(jsonEncode(cfg), {
        'name': c.name,
        'killSwitch': settings.get<bool>('killSwitch'),
        'ipv6': settings.get<bool>('ipv6'),
        'mtu': settings.get<int>('mtu'),
        'dns': dnsServersFor(settings),
        'fakeDns': settings.get<bool>('fakeDns'),
        'sniff': settings.get<bool>('sniffing'),
        'routeLists': lists,
        'perAppMode': settings.get<String>('perAppMode'),
        'perApps': settings.list('perApps'),
        'wakeMode': settings.get<String>('wakeMode'),
        'bootStart': settings.get<bool>('bootStart'),
        'allowBypass': settings.get<bool>('allowBypass'),
        'excludeLan': settings.get<bool>('excludeLan'),
        'useUnderlying': settings.get<bool>('useUnderlying'),
        'notifShowServer': settings.get<bool>('notifShowServer') && !c.locked,
        'notifHideLock': settings.get<bool>('notifHideLock'),
      });
      final limits = [settings.get<int>('sleepTimer'), c.maxSessionMin ?? 0].where((m) => m > 0).toList()..sort();
      final mins = limits.isEmpty ? 0 : limits.first;
      sleepAt = mins > 0 ? DateTime.now().add(Duration(minutes: mins)) : null;
      // The library allows each server its own attempt (12 s, or the connect timeout when that is longer),
      // so with backups the overall limit has to cover all of them.
      final each = max(12, settings.get<int>('connectTimeout'));
      final servers = 1 + ((cfg['backups'] as List?)?.length ?? 0);
      _timeout?.cancel();
      _timeout = Timer(Duration(seconds: each * servers + 10), () {
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
    _setStatus(VpnStatus.disconnected);
    if (settings.get<bool>('clearLogsOnDisconnect')) clearLogs();
  }

  void _fail(String msg) {
    lastError = msg;
    log('error', msg);
    bridge.stop().catchError((_) {});
    _setStatus(VpnStatus.error);
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

  ServerConfig? _byId(String id) => configs.where((x) => x.id == id).firstOrNull;

  void _tick() {
    final c = selected;
    if (c != null && c.dataLimitReached && status == VpnStatus.connected) {
      lastError = 'The data limit of this config has been used up.';
      log('warn', 'Data limit reached for "${c.safeHost == c.host ? c.name : 'locked config'}". Disconnecting.');
      disconnect();
      return;
    }
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
    final sel = selected;
    if (sel != null && sel.dataLimitMb != null) {
      sel.usedBytes += (rx < 0 ? 0 : rx) + (tx < 0 ? 0 : tx);
      if (_usageTicks % 15 == 0) _save();
    }
    final month = settings.get<int>('monthlyCapMb');
    if (month > 0 && !capExceeded && monthBytes() > month * 1024 * 1024) {
      capExceeded = true;
      log('warn', 'Monthly data limit of $month MB reached');
    }
    if (usage.length > 90) usage.remove((usage.keys.toList()..sort()).first);
    final cap = settings.get<int>('dailyCapMb');
    if (cap > 0 && (e[0] + e[1]) > cap * 1024 * 1024 && !capExceeded) {
      capExceeded = true;
      log('warn', 'Daily data limit of $cap MB reached');
    }
    if (++_usageTicks % 15 == 0) _saveUsage();
  }

  int monthBytes() {
    final prefix = dayKey(DateTime.now()).substring(0, 7);
    return usage.entries.where((e) => e.key.startsWith(prefix)).fold(0, (a, e) => a + e.value[0] + e.value[1]);
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
      if (settings.get<String>('pin').isNotEmpty && DateTime.now().difference(_bgAt!).inSeconds >= settings.get<int>('autoLockSec')) {
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
    applySecure();
    refreshSubscriptions();
    if (settings.get<bool>('autoConnect') && selected != null && status == VpnStatus.disconnected) {
      await connect();
    }
  }

  /// HttpClient for the Tools tab. The app is not excluded from the VPN (the library protects its own sockets),
  /// so while connected an ordinary client already goes through the tunnel.
  HttpClient tunnelClient() => HttpClient()..connectionTimeout = const Duration(seconds: 10);

  @override
  void dispose() {
    _ticker?.cancel();
    _timeout?.cancel();
    _retryTimer?.cancel();
    _routingTimer?.cancel();
    super.dispose();
  }
}
