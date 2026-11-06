import 'dart:convert';

enum Proto { vless, vmess, trojan, shadowsocks, ssh, socks5, socks4, http, https, hysteria2, hysteria1 }

extension ProtoX on Proto {
  String get label => switch (this) {
        Proto.vless => 'VLESS',
        Proto.vmess => 'VMess',
        Proto.trojan => 'Trojan',
        Proto.shadowsocks => 'Shadowsocks',
        Proto.ssh => 'SSH',
        Proto.socks5 => 'SOCKS5',
        Proto.socks4 => 'SOCKS4',
        Proto.http => 'HTTP',
        Proto.https => 'HTTPS',
        Proto.hysteria2 => 'Hysteria 2',
        Proto.hysteria1 => 'Hysteria 1',
      };

  /// Short badge text for list tiles.
  String get badge => switch (this) {
        Proto.vless => 'VL',
        Proto.vmess => 'VM',
        Proto.trojan => 'TR',
        Proto.shadowsocks => 'SS',
        Proto.ssh => 'SSH',
        Proto.socks5 => 'S5',
        Proto.socks4 => 'S4',
        Proto.http => 'HT',
        Proto.https => 'HS',
        Proto.hysteria2 => 'H2',
        Proto.hysteria1 => 'H1',
      };

  /// The `protocol` value of the V2-TUN config.
  String get libName => switch (this) {
        Proto.hysteria1 => 'hysteria',
        _ => name,
      };

  /// Hysteria brings its own QUIC/TLS: no payload, transports, REALITY or fragmenting.
  bool get isHysteria => this == Proto.hysteria2 || this == Proto.hysteria1;

  /// Protocols that can share one connection through Mux.Cool.
  bool get canMux => this == Proto.vless || this == Proto.vmess || this == Proto.trojan || this == Proto.shadowsocks;
}

/// One server profile. Protocol specific values live in [params] and map one to one onto the V2-TUN config:
/// id (uuid / password / auth string), user, method, net, security (none|tls|reality), sni, fp, pbk, sid, path,
/// host (ws/h2/xhttp host header), flow, alpn, serviceName, mode, aid, privateKey, allowInsecure,
/// payload, payloadHost, payloadStage, proxy (HTTP proxy host:port for the payload), responseMap (e.g. 301=200),
/// obfs, pin (hysteria2 certificate SHA-256), upMbps, downMbps.
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
    this.maxSessionMin,
    this.dataLimitMb,
    this.usedBytes = 0,
    this.blockRooted = false,
    this.secure = false,
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

  // ── Limits and protections set by whoever shared the config ──
  int? maxSessionMin; // auto-disconnect after N minutes of one session
  int? dataLimitMb; // total data this config may use
  int usedBytes; // data used so far (counted on this device)
  bool blockRooted; // refuse to run on rooted devices
  bool secure; // block screenshots while this profile is selected

  bool get dataLimitReached => dataLimitMb != null && usedBytes >= dataLimitMb! * 1024 * 1024;
  int? get dataLeftBytes => dataLimitMb == null ? null : (dataLimitMb! * 1024 * 1024 - usedBytes).clamp(0, 1 << 62);

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

  /// Profiles saved by older versions kept SSH transport settings under other keys. Moves them onto the
  /// V2-TUN names (transport tls -> security tls, transport http -> payload with an HTTP proxy).
  void migrate() {
    if (proto != Proto.ssh) return;
    final t = params.remove('transport');
    final ph = params.remove('proxyHost') ?? '';
    final pp = params.remove('proxyPort') ?? '';
    final rr = params.remove('responseRewrite') ?? '';
    if (t == 'tls') params['security'] = 'tls';
    if (t == 'http') {
      if (ph.isNotEmpty || pp.isNotEmpty) params['proxy'] = '${ph.isEmpty ? host : ph}:${pp.isEmpty ? port : pp}';
      if ((params['payload'] ?? '').isEmpty) params['payload'] = '@connect';
      if (rr.isNotEmpty) params['responseMap'] = rr;
    }
  }

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
        if (maxSessionMin != null) 'sess': maxSessionMin,
        if (dataLimitMb != null) 'cap': dataLimitMb,
        if (usedBytes > 0) 'used': usedBytes,
        if (blockRooted) 'noRoot': true,
        if (secure) 'secure': true,
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
        maxSessionMin: j['sess'] as int?,
        dataLimitMb: j['cap'] as int?,
        usedBytes: j['used'] as int? ?? 0,
        blockRooted: j['noRoot'] as bool? ?? false,
        secure: j['secure'] as bool? ?? false,
      )..migrate();

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
    'haptics': true,
    'perAppMode': 'off', // off | exclude | only
    'perApps': <String>[],
    // strength of the Android wake/Wi-Fi locks: off | balanced | strong
    'wakeMode': 'strong',
    'bootStart': false,
    'sleepTimer': 0, // minutes, 0 = off
    'smartConnect': false, // pick the lowest-latency server on connect
    'dnsPreset': 'cloudflare', // cloudflare | google | quad9 | adguard | custom
    'customRules': '', // one per line: proxy|direct|block domain:example.com
    'pin': '', // salted hash of the app lock PIN, empty = off
    'dailyCapMb': 0, // 0 = no data warning
    'subRefreshHours': 24,

    // ── Routing (V2-TUN routing engine) ──
    'bypassCountry': 'none', // none | cn | ir | ru  (direct for that country's sites and IPs)
    'blockQuic': false,
    'blockBittorrent': false, // needs sniffing
    'domainStrategy': 'IPIfNonMatch', // AsIs | IPIfNonMatch | IPOnDemand
    // Lists for geoip:XX / geosite:XX rules. V2-TUN bundles none, the app downloads these text lists.
    'listAdsUrl': 'https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt',
    'listDirectUrl': 'https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt',
    'listIpBase': 'https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text',
    'listRefreshDays': 7,

    // ── DNS ──
    'directDns': '1.1.1.1:53', // protected resolver for server and direct hostnames (bypasses the VPN)
    'fakeDns': false, // fake-IP DNS: domain rules work for DNS based apps
    'sniffing': true, // SNI / Host / protocol sniffing on the tunnel (needed for domain and protocol rules)

    // ── Tunnel core (V2-TUN) ──
    'mux': false,
    'muxConcurrency': 8,
    'fragment': false,
    'fragLength': '100-200',
    'fragInterval': '10-20',
    'allowInsecure': false,
    'defaultFp': '', // uTLS fingerprint for TLS profiles that do not set one
    'udpgw': '', // BadVPN udpgw address as seen from the server (UDP over SSH, SOCKS and HTTP proxies)
    'connectTimeout': 15,
    'failoverMode': 'off', // off | ordered: try the extra servers one after the other when connecting fails
    'failoverIds': <String>[],

    // ── Android / privacy ──
    'allowBypass': false, // let apps opt out of the VPN
    'excludeLan': false, // Android 13+: keep LAN traffic out of the tunnel
    'useUnderlying': true, // tell Android which real network carries the tunnel
    'notifShowServer': true,
    'notifHideLock': true, // hide notification text on the lock screen
    'secureScreen': false, // block screenshots and recent-apps preview
    'autoLockSec': 30, // PIN re-lock delay in seconds (0 = immediately)
    'clearLogsOnDisconnect': false,
    'monthlyCapMb': 0,
  };

  final Map<String, dynamic> _m;
  T get<T>(String k) => _m[k] as T;
  List<String> list(String k) => (_m[k] as List).cast<String>();
  void set(String k, dynamic v) => _m[k] = v;
  Map<String, dynamic> toJson() => _m;
}
