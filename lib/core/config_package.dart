import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'models.dart';

/// What the sender attaches to a shared config. Modelled on the "provider mode"
/// found in tunnelling apps: custom message, expiry, locking and device binding.
class ShareMeta {
  ShareMeta({
    this.title = '',
    this.note = '',
    this.author = '',
    this.expiresAt,
    this.validDays,
    this.locked = false,
    this.allowReshare = true,
    this.deviceHash,
  });

  String title, note, author;
  DateTime? expiresAt;
  int? validDays;
  bool locked, allowReshare;
  String? deviceHash;

  Map<String, dynamic> toJson() => {
        'title': title,
        'note': note,
        'author': author,
        if (expiresAt != null) 'exp': expiresAt!.toUtc().toIso8601String(),
        if (validDays != null) 'days': validDays,
        'locked': locked,
        'reshare': allowReshare,
        if (deviceHash != null) 'dev': deviceHash,
        'created': DateTime.now().toUtc().toIso8601String(),
      };

  factory ShareMeta.fromJson(Map<String, dynamic> j) => ShareMeta(
        title: j['title'] as String? ?? '',
        note: j['note'] as String? ?? '',
        author: j['author'] as String? ?? '',
        expiresAt: j['exp'] == null ? null : DateTime.parse(j['exp'] as String).toUtc(),
        validDays: j['days'] as int?,
        locked: j['locked'] as bool? ?? false,
        allowReshare: j['reshare'] as bool? ?? true,
        deviceHash: j['dev'] as String?,
      );
}

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NeedsPassword implements Exception {}

/// A shareable bundle: one or more profiles plus [ShareMeta], AES-256-GCM encrypted.
///
/// * Without a password the key is derived from a constant inside the app. That hides the
///   contents from casual inspection (like other tunnel apps' "locked" files), but it is
///   obfuscation, not secrecy: anyone with the app can open it.
/// * With a password the key comes from PBKDF2-HMAC-SHA256 and the file is only readable by
///   people who know the password.
/// A locked config still has to hand its credentials to the VPN core to work, so a determined
/// user on a rooted device can always recover them. Treat lock as a deterrent.
class ConfigPackage {
  ConfigPackage(this.meta, this.profiles);
  final ShareMeta meta;
  final List<ServerConfig> profiles;

  static const _scheme = 'xrayvpn';
  static const _iterations = 60000;
  static final _aes = AesGcm.with256bits();

  static List<int> _rand(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  static Future<SecretKey> _key(String? password, List<int> salt) async {
    if (password == null || password.isEmpty) {
      final h = await Sha256().hash(utf8.encode('io.surprise.vpn/xrcfg/v1'));
      return SecretKey(h.bytes);
    }
    return Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _iterations, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
  }

  static Future<String> encode(ShareMeta meta, List<ServerConfig> profiles, {String? password}) async {
    final payload = jsonEncode({
      'meta': meta.toJson(),
      'profiles': profiles.map((c) {
        final j = c.toJson();
        // Never carry the sender's own import state or ids into the package.
        for (final k in ['id', 'ping', 'fav', 'group', 'imp', 'locked', 'noShare', 'dev', 'exp', 'days', 'note', 'author']) {
          j.remove(k);
        }
        return j;
      }).toList(),
    });
    final salt = _rand(16);
    final nonce = _rand(12);
    final key = await _key(password, salt);
    final box = await _aes.encrypt(utf8.encode(payload), secretKey: key, nonce: nonce);
    return jsonEncode({
      'xrcfg': 1,
      'enc': (password == null || password.isEmpty) ? 'app' : 'pass',
      'salt': base64.encode(salt),
      'nonce': base64.encode(nonce),
      'ct': base64.encode(box.cipherText),
      'mac': base64.encode(box.mac.bytes),
    });
  }

  static String toLink(String envelope) => '$_scheme://import?d=${base64Url.encode(utf8.encode(envelope))}';

  /// Accepts a deep link or a raw envelope. Returns the envelope map or null.
  static Map<String, dynamic>? peek(String text) {
    var t = text.trim();
    try {
      if (t.startsWith('$_scheme://')) {
        final d = Uri.parse(t).queryParameters['d'];
        if (d == null) return null;
        t = utf8.decode(base64Url.decode(base64Url.normalize(d)));
      }
      if (!t.startsWith('{')) return null;
      final m = jsonDecode(t) as Map<String, dynamic>;
      return m['xrcfg'] == null ? null : m;
    } catch (_) {
      return null;
    }
  }

  static bool needsPassword(Map<String, dynamic> env) => env['enc'] == 'pass';

  static Future<ConfigPackage> decode(Map<String, dynamic> env, {String? password}) async {
    if (needsPassword(env) && (password == null || password.isEmpty)) throw NeedsPassword();
    try {
      final salt = base64.decode(env['salt'] as String);
      final key = await _key(needsPassword(env) ? password : null, salt);
      final box = SecretBox(base64.decode(env['ct'] as String),
          nonce: base64.decode(env['nonce'] as String), mac: Mac(base64.decode(env['mac'] as String)));
      final plain = await _aes.decrypt(box, secretKey: key);
      final j = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final profiles = (j['profiles'] as List).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        m['id'] = ServerConfig.newId();
        return ServerConfig.fromJson(m);
      }).toList();
      return ConfigPackage(ShareMeta.fromJson(j['meta'] as Map<String, dynamic>), profiles);
    } on NeedsPassword {
      rethrow;
    } catch (_) {
      throw ImportException(needsPassword(env) ? 'Wrong password, or the file is damaged.' : 'This config file is damaged or from an incompatible version.');
    }
  }

  static Future<String> hashDeviceId(String code) async {
    final norm = code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    return base64Url.encode((await Sha256().hash(utf8.encode('xray-device:$norm'))).bytes);
  }

  /// Checks expiry and device binding, then stamps the metadata onto each profile.
  Future<List<ServerConfig>> prepareImport(String myDeviceId) async {
    if (meta.expiresAt != null && meta.expiresAt!.isBefore(DateTime.now().toUtc())) {
      throw ImportException('This config expired on ${meta.expiresAt!.toLocal().toString().substring(0, 10)}.');
    }
    if (meta.deviceHash != null && meta.deviceHash != await hashDeviceId(myDeviceId)) {
      throw ImportException('This config is locked to a different device. Send the sender your Device ID (Settings → About).');
    }
    final now = DateTime.now().toUtc();
    for (final c in profiles) {
      if (meta.title.isNotEmpty) c.name = profiles.length == 1 ? meta.title : '${meta.title} · ${c.name}';
      c.note = meta.note;
      c.author = meta.author;
      c.expiresAt = meta.expiresAt;
      c.validDays = meta.validDays;
      c.importedAt = now;
      c.locked = meta.locked;
      c.allowShare = meta.allowReshare;
      c.deviceHash = meta.deviceHash;
    }
    return profiles;
  }
}
