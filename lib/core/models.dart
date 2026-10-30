import 'dart:convert';

enum Proto { vless, vmess, trojan, shadowsocks, ssh }

extension ProtoX on Proto {
  String get label => switch (this) {
        Proto.vless => 'VLESS',
        Proto.vmess => 'VMess',
        Proto.trojan => 'Trojan',
        Proto.shadowsocks => 'Shadowsocks',
        Proto.ssh => 'SSH',
      };
}

/// One server profile. Protocol specific values live in [params]:
/// id (uuid/password), method, net, security, sni, fp, pbk, sid, spx, path,
/// host, flow, alpn, serviceName, mode, aid, user, privateKey, passphrase.
class ServerConfig {
  ServerConfig({
    required this.id,
    required this.name,
    required this.proto,
    required this.host,
    required this.port,
    Map<String, String>? params,
    this.pingMs,
    this.favorite = false,
    this.group = '',
    this.note = '',
    this.expiresAt,
    this.validDays,
    this.importedAt,
    this.locked = false,
    this.allowShare = true,
    this.deviceHash,
    this.author = '',
  }) : params = params ?? {};

  final String id;
  String name;
  Proto proto;
  String host;
  int port;
  Map<String, String> params;
  int? pingMs;
  bool favorite;
  String group;

  // ── Provider-style metadata (set when a shared package is imported) ──
  String note; // message from whoever shared it
  DateTime? expiresAt; // absolute expiry (UTC)
  int? validDays; // or: valid for N days after import
  DateTime? importedAt;
  bool locked; // hide host/credentials, block editing and export
  bool allowShare; // may the importer re-share it?
  String? deviceHash; // bound to one device
  String author;

  DateTime? get effectiveExpiry {
    DateTime? e = expiresAt;
    if (validDays != null && importedAt != null) {
      final r = importedAt!.add(Duration(days: validDays!));
      if (e == null || r.isBefore(e)) e = r;
    }
    return e;
  }

  bool get expired => effectiveExpiry?.isBefore(DateTime.now().toUtc()) ?? false;

  /// Name that is safe to show in logs/UI. Locked profiles never reveal the host.
  String get safeHost => locked ? 'locked server' : host;

  String p(String k, [String d = '']) {
    final v = params[k];
    return (v == null || v.isEmpty) ? d : v;
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'proto': proto.name,
        'host': host,
        'port': port,
        'params': params,
        'ping': pingMs,
        'fav': favorite,
        'group': group,
        if (note.isNotEmpty) 'note': note,
        if (expiresAt != null) 'exp': expiresAt!.toUtc().toIso8601String(),
        if (validDays != null) 'days': validDays,
        if (importedAt != null) 'imp': importedAt!.toUtc().toIso8601String(),
        if (locked) 'locked': true,
        if (!allowShare) 'noShare': true,
        if (deviceHash != null) 'dev': deviceHash,
        if (author.isNotEmpty) 'author': author,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        proto: Proto.values.byName(j['proto'] as String),
        host: j['host'] as String,
        port: j['port'] as int,
        params: Map<String, String>.from(j['params'] as Map? ?? {}),
        pingMs: j['ping'] as int?,
        favorite: j['fav'] as bool? ?? false,
        group: j['group'] as String? ?? '',
        note: j['note'] as String? ?? '',
        expiresAt: j['exp'] == null ? null : DateTime.parse(j['exp'] as String).toUtc(),
        validDays: j['days'] as int?,
        importedAt: j['imp'] == null ? null : DateTime.parse(j['imp'] as String).toUtc(),
        locked: j['locked'] as bool? ?? false,
        allowShare: !(j['noShare'] as bool? ?? false),
        deviceHash: j['dev'] as String?,
        author: j['author'] as String? ?? '',
      );

  @override
  String toString() => jsonEncode(toJson());
}

class LogEntry {
  LogEntry(this.level, this.message) : time = DateTime.now();
  final DateTime time;
  final String level; // info | warn | error
  final String message;
}

/// Map backed settings so adding an option is a one-line change.
class AppSettings {
  AppSettings([Map<String, dynamic>? saved]) : _m = {...defaults, ...?saved};

  static const Map<String, dynamic> defaults = {
    'themeMode': 2, // 0 system, 1 light, 2 dark
    'accent': 0, // index into Accents.presets, 6 = custom
    'customAccent': 0xFF5BB8AE,
    'blur': 18.0,
    'routing': 'bypassLan', // global | bypassLan | bypassLanAds
    'ipv6': false,
    'mtu': 1500,
    'dns1': '1.1.1.1',
    'dns2': '8.8.8.8',
    'killSwitch': false,
    'autoReconnect': true,
    'autoConnect': false,
    'sniffing': true,
    'mux': false,
    'fragment': false,
    'allowInsecure': false,
    'logLevel': 'warning',
    'socksPort': 10808,
    'perAppMode': 'off', // off | exclude | only
    'perApps': <String>[],
    'sshKeepAlive': 20,
    'haptics': true,
    // strength of the Android wake/Wi-Fi locks: off | balanced | strong
    'wakeMode': 'strong',
    'bootStart': false,
    'sleepTimer': 0, // minutes, 0 = off
    'smartConnect': false, // pick the lowest-latency server on connect
    'blockQuic': false,
    'dnsPreset': 'cloudflare', // cloudflare | google | quad9 | adguard | custom
    'customRules': '', // one per line: proxy|direct|block domain:example.com
    'pin': '', // salted hash of the app lock PIN, empty = off
    'dailyCapMb': 0, // 0 = no data warning
    'subRefreshHours': 24,
  };

  final Map<String, dynamic> _m;
  T get<T>(String k) => _m[k] as T;
  List<String> list(String k) => (_m[k] as List).cast<String>();
  void set(String k, dynamic v) => _m[k] = v;
  Map<String, dynamic> toJson() => _m;
}
