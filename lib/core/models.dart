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

    // ── Routing ──
    'bypassCountry': 'none', // none | cn | ir | ru  (direct for that country's sites and IPs)
    'blockBittorrent': false,
    'domainStrategy': 'IPIfNonMatch', // AsIs | IPIfNonMatch | IPOnDemand

    // ── DNS ──
    'dnsRemote': '', // custom preset: comma separated servers (IPs, https://, tcp://, quic+local://)
    'dnsDoh': false, // use DNS-over-HTTPS endpoints of the chosen provider
    'dnsHosts': '', // static entries, one per line: `example.com 1.2.3.4`
    'dnsStrategy': 'auto', // auto | UseIP | UseIPv4 | UseIPv6
    'dnsCache': true,
    'fakeDns': false,

    // ── Xray core ──
    'sniffOverride': 'http,tls,quic',
    'routeOnly': true,
    'muxConcurrency': 8,
    'xudpConcurrency': 16,
    'xudpProxyUDP443': 'reject', // reject | allow | skip
    'fragPackets': 'tlshello',
    'fragLength': '100-200',
    'fragInterval': '10-20',
    'tcpFastOpen': false,
    'tcpMptcp': false,
    'tcpKeepAlive': 0, // seconds, 0 = system default
    'sockoptDomainStrategy': 'AsIs',
    'defaultFp': '', // uTLS fingerprint for TLS profiles that do not set one
    'allowLan': false, // share the tunnel with other devices (SOCKS/HTTP on the LAN)
    'localUser': '',
    'localPass': '',
    'failoverMode': 'off', // off | leastPing | random | roundRobin
    'failoverIds': <String>[],
    'chainId': '', // entry hop for double-VPN
    'xrayJson': '', // JSON merged over the generated config
    'connIdle': 300,
    'probeSeconds': 30,

    // ── SSH ──
    'sshConnectTimeout': 15,
    'sshHostKeyPolicy': 'tofu', // tofu | strict | off
    'sshLocalPort': 0, // 0 = socksPort + 2
    'sshMaxConnections': 256,
    'sshNoDelay': true,
    'sshJumpId': '', // connect to the SSH server through another SSH profile

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
    'geoBase': 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download',
  };

  final Map<String, dynamic> _m;
  T get<T>(String k) => _m[k] as T;
  List<String> list(String k) => (_m[k] as List).cast<String>();
  void set(String k, dynamic v) => _m[k] = v;
  Map<String, dynamic> toJson() => _m;
}
