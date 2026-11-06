import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Downloads and caches the text lists behind `geoip:XX`, `geosite:XX` and `list:NAME` routing entries.
/// V2-TUN ships no country data; the VPN service reads these files at start and hands them to the library.
class RouteLists {
  static Future<Directory> dir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/routelists');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// File name for a list name, e.g. `geoip:cn` -> `geoip_cn.txt`.
  static String fileName(String name) => '${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.txt';

  static const _maxBytes = 40 * 1024 * 1024;

  /// Makes sure every wanted list is on disk, downloading missing ones and ones older than [maxAgeDays] (or all when
  /// [force]). A failed refresh keeps the older copy. Returns list name -> file name for the lists that exist.
  static Future<Map<String, String>> prepare(
    Map<String, String> sources, {
    bool force = false,
    int maxAgeDays = 7,
    void Function(String level, String message)? log,
  }) async {
    final d = await dir();
    final out = <String, String>{};
    for (final e in sources.entries) {
      final f = File('${d.path}/${fileName(e.key)}');
      final exists = await f.exists();
      final stale = !exists || force || DateTime.now().difference(await f.lastModified()).inDays >= maxAgeDays;
      if (stale) {
        try {
          await _download(e.value, f);
          log?.call('info', 'Updated list ${e.key}');
        } catch (err) {
          log?.call(exists ? 'warn' : 'error', 'List ${e.key} could not be downloaded ($err)${exists ? '; using the saved copy' : '; rules that use it will not match'}');
        }
      }
      if (await f.exists()) out[e.key] = fileName(e.key);
    }
    return out;
  }

  /// Size and age of the saved lists, for the settings page.
  static Future<Map<String, String>> status(Iterable<String> names) async {
    final d = await dir();
    final m = <String, String>{};
    for (final n in names) {
      final f = File('${d.path}/${fileName(n)}');
      m[n] = await f.exists() ? '${(await f.length() / 1024).round()} KB · ${(await f.lastModified()).toString().substring(0, 10)}' : 'Not downloaded';
    }
    return m;
  }

  static Future<void> _download(String url, File dest) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    final tmp = File('${dest.path}.part');
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'XRayVPN/1.0');
      final res = await req.close();
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      final sink = tmp.openWrite();
      var n = 0;
      await for (final chunk in res) {
        n += chunk.length;
        if (n > _maxBytes) throw 'the list is larger than 40 MB';
        sink.add(chunk);
      }
      await sink.close();
      if (n < 16) throw 'the download looks empty';
      await tmp.rename(dest.path);
    } finally {
      client.close(force: true);
      if (await tmp.exists()) await tmp.delete();
    }
  }
}
