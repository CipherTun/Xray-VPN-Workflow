import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/link_parser.dart';
import '../core/v2tun_config.dart';
import '../core/vpn_bridge.dart';
import '../state/app_state.dart';
import 'library_options_page.dart';
import 'theme.dart';
import 'widgets.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const PageHeader('Tools', subtitle: 'Checks run through the tunnel library'),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 120), children: const [
          _IpCard(),
          SizedBox(height: 12),
          _SpeedCard(),
          SizedBox(height: 12),
          _LatencyCard(),
          SizedBox(height: 12),
          _ScanCard(),
          SizedBox(height: 12),
          _CheckCard(),
          SizedBox(height: 12),
          _RouteCard(),
          SizedBox(height: 12),
          _ReachCard(),
          SizedBox(height: 12),
          _UsageCard(),
          SizedBox(height: 12),
          _DnsCard(),
          SizedBox(height: 12),
          _OptionsCard(),
          SizedBox(height: 12),
          _ExportCard(),
        ]),
      ),
    ]);
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.icon, required this.title, required this.child, this.action});
  final IconData icon;
  final String title;
  final Widget child;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Glass(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(12)), child: Icon(icon, size: 19, color: p.accent)),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          if (action != null) action!,
        ]),
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}

Widget _btn(BuildContext c, String label, VoidCallback? on) {
  final p = c.pal;
  return FilledButton(
    onPressed: on,
    style: FilledButton.styleFrom(backgroundColor: p.accentSoft, foregroundColor: p.accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
  );
}

InputDecoration _field(String? hint, {String? label}) => InputDecoration(
      isDense: true,
      filled: true,
      hintText: hint,
      labelText: label,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    );

/// Text of an error from the native side without the PlatformException wrapper.
String _msg(Object e) => e is PlatformException ? (e.message ?? e.code) : '$e';

/// The V2-TUN config of the selected server for the library's own checks. [forPing] leaves routing out so the
/// check always goes through the server, whatever the rules say. Either `json` or `error` is set.
({String? json, String? error}) _libConfig(AppState s, {bool forPing = true}) {
  final sel = s.selected;
  if (sel == null) return (json: null, error: 'Select a server first.');
  if (sel.expired) return (json: null, error: 'This config has expired.');
  try {
    return (json: jsonEncode(s.configFor(sel, forPing: forPing, quiet: true)), error: null);
  } on V2tunConfigError catch (e) {
    return (json: null, error: e.message);
  }
}

// ───────── public IP ─────────
class _IpCard extends StatefulWidget {
  const _IpCard();
  @override
  State<_IpCard> createState() => _IpCardState();
}

class _IpCardState extends State<_IpCard> {
  String? text;
  bool busy = false;

  Future<void> run() async {
    final s = context.read<AppState>();
    setState(() => busy = true);
    final c = s.tunnelClient();
    try {
      final r = await (await c.getUrl(Uri.parse('https://ipwho.is/'))).close();
      final j = jsonDecode(await r.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final conn = (j['connection'] as Map?) ?? {};
      text = '${j['ip']}\n${j['city'] ?? ''}, ${j['country'] ?? ''}\n${conn['isp'] ?? ''}';
    } catch (e) {
      text = 'Could not check: $e';
    } finally {
      c.close(force: true);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final on = context.select<AppState, bool>((s) => s.isOn);
    return _ToolCard(
      icon: Icons.public_rounded,
      title: 'Public IP',
      action: _btn(context, busy ? 'Checking…' : 'Check', busy ? null : run),
      child: Text(text ?? (on ? 'Check the address websites see.' : 'Not connected: this shows your normal address.'), style: TextStyle(color: text == null ? p.dim : p.text, height: 1.45, fontSize: 14)),
    );
  }
}

// ───────── speed (the library's own SpeedTest) ─────────
class _SpeedCard extends StatefulWidget {
  const _SpeedCard();
  @override
  State<_SpeedCard> createState() => _SpeedCardState();
}

class _SpeedCardState extends State<_SpeedCard> {
  double? mbps;
  int? bytes;
  bool busy = false;
  String? err;

  Future<void> run() async {
    final s = context.read<AppState>();
    final r = _libConfig(s);
    if (r.json == null) {
      setState(() { err = r.error; mbps = null; });
      return;
    }
    setState(() { busy = true; mbps = null; bytes = null; err = null; });
    try {
      final (n, bps) = await s.bridge.speedTest(r.json!, seconds: 10);
      if (mounted) setState(() { mbps = bps / 1e6; bytes = n; });
    } catch (e) {
      if (mounted) setState(() => err = _msg(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _ToolCard(
      icon: Icons.speed_rounded,
      title: 'Download speed',
      action: _btn(context, busy ? 'Testing…' : 'Start', busy ? null : run),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          err != null ? 'Test failed: $err' : mbps == null ? 'Downloads through the selected server for up to 10 seconds. Works with or without the VPN on.' : '${mbps!.toStringAsFixed(1)} Mbit/s',
          style: TextStyle(fontSize: err == null && mbps != null ? 26 : 14, fontWeight: FontWeight.w800, color: err != null ? p.bad : (mbps == null ? p.dim : p.text), height: 1.4),
        ),
        if (bytes != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${fmtBytes(bytes!)} downloaded', style: TextStyle(color: p.dim, fontSize: 12.5))),
        if (busy) Padding(padding: const EdgeInsets.only(top: 10), child: LinearProgressIndicator(color: p.accent, backgroundColor: alpha(p.dim, .2), borderRadius: BorderRadius.circular(6))),
      ]),
    );
  }
}

// ───────── latency ─────────
class _LatencyCard extends StatefulWidget {
  const _LatencyCard();
  @override
  State<_LatencyCard> createState() => _LatencyCardState();
}

class _LatencyCardState extends State<_LatencyCard> {
  String? text;
  bool busy = false;

  Future<void> run() async {
    final s = context.read<AppState>();
    setState(() => busy = true);
    final lines = <String>[];
    final sel = s.selected;
    if (sel != null) {
      // A request through the library with this profile, so it also proves the credentials work.
      await s.pingOne(sel);
      lines.add('Server (full request): ${sel.pingMs! < 0 ? 'failed' : '${sel.pingMs} ms'}');
    }
    if (s.isOn) {
      // With failover on, the library says which of the servers is carrying the tunnel right now.
      final ao = await s.bridge.activeOutbound();
      if (ao == 0) {
        lines.add('In use: the selected server');
      } else if (ao > 0) {
        lines.add('In use: failover backup #$ao');
      }
    }
    final c = s.tunnelClient();
    try {
      final sw = Stopwatch()..start();
      final r = await (await c.getUrl(Uri.parse('https://cp.cloudflare.com/generate_204'))).close();
      await r.drain();
      lines.add('Through tunnel (HTTPS): ${sw.elapsedMilliseconds} ms');
    } catch (e) {
      lines.add('Through tunnel: failed');
    } finally {
      c.close(force: true);
    }
    if (mounted) setState(() { text = lines.join('\n'); busy = false; });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _ToolCard(
      icon: Icons.network_ping_rounded,
      title: 'Latency',
      action: _btn(context, busy ? 'Testing…' : 'Test', busy ? null : run),
      child: Text(text ?? 'Round-trip time to the selected server and through the tunnel, and which server is in use.', style: TextStyle(color: text == null ? p.dim : p.text, height: 1.5)),
    );
  }
}

// ───────── host scanner (the library's ScanHosts) ─────────
class _ScanCard extends StatefulWidget {
  const _ScanCard();
  @override
  State<_ScanCard> createState() => _ScanCardState();
}

class _ScanCardState extends State<_ScanCard> {
  static const fields = ['payload.host', 'tls.sni', 'ws.host', 'payload.proxy', 'server'];
  static const _paramOf = {'payload.host': 'payloadHost', 'tls.sni': 'sni', 'ws.host': 'host', 'payload.proxy': 'proxy'};
  static const _maxHosts = 200;

  final hosts = TextEditingController();
  final target = TextEditingController(text: 'http://www.gstatic.com/generate_204');
  String field = 'payload.host';
  int jobs = 3;
  int seconds = 15;
  bool busy = false;
  String? err;
  List<ScanResult>? results;

  @override
  void dispose() {
    hosts.dispose();
    target.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final s = context.read<AppState>();
    final r = _libConfig(s);
    if (r.json == null) {
      setState(() { err = r.error; results = null; });
      return;
    }
    final lines = hosts.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty && !e.startsWith('#')).toList();
    if (lines.isEmpty) {
      setState(() { err = 'Add some hosts to try, one per line.'; results = null; });
      return;
    }
    if (lines.length > _maxHosts) toast(context, 'Only the first $_maxHosts hosts are scanned.');
    setState(() { busy = true; err = null; results = null; });
    try {
      final out = await s.bridge.scanHosts(
        r.json!,
        field: field,
        values: lines.take(_maxHosts).join('\n'),
        target: target.text.trim(),
        concurrency: jobs,
        seconds: seconds,
      );
      // Working hosts first, fastest first.
      out.sort((a, b) {
        if (a.ok != b.ok) return a.ok ? -1 : 1;
        return a.ms.compareTo(b.ms);
      });
      if (mounted) setState(() => results = out);
    } catch (e) {
      if (mounted) setState(() => err = _msg(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _paste() async {
    final t = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (t.trim().isEmpty) {
      if (mounted) toast(context, 'The clipboard is empty.');
      return;
    }
    setState(() => hosts.text = t);
  }

  void _use(ScanResult r) {
    final s = context.read<AppState>();
    final sel = s.selected;
    if (sel == null) return;
    if (sel.locked) {
      toast(context, 'Locked configs cannot be edited.');
      return;
    }
    if (field == 'server') {
      sel.host = r.value;
    } else {
      sel.params[_paramOf[field]!] = r.value;
    }
    s.upsert(sel);
    toast(context, 'Set ${field == 'server' ? 'the server' : field} of "${sel.name}" to ${r.value}');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final res = results;
    final good = res?.where((e) => e.ok).length ?? 0;
    return _ToolCard(
      icon: Icons.radar_rounded,
      title: 'Host scanner',
      action: _btn(context, busy ? 'Scanning…' : 'Scan', busy ? null : run),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Tries the selected server once per host below, with that host in the chosen field, and shows which ones your network lets through.', style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final f in fields) ChoiceChip(label: Text(f), selected: field == f, onSelected: busy ? null : (_) => setState(() => field = f)),
        ]),
        const SizedBox(height: 10),
        TextField(controller: hosts, minLines: 4, maxLines: 6, autocorrect: false, enabled: !busy, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5), decoration: _field('One host per line\nbug.example.com\ncdn.example.net')),
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: busy ? null : _paste, icon: const Icon(Icons.paste_rounded, size: 18), label: const Text('Paste list'))),
        TextField(controller: target, autocorrect: false, enabled: !busy, decoration: _field('http://www.gstatic.com/generate_204 or host:443', label: 'Test target')),
        const SizedBox(height: 10),
        Row(children: [
          Text('Parallel', style: TextStyle(color: p.dim, fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          for (final n in const [1, 3, 5]) Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text('$n'), selected: jobs == n, onSelected: busy ? null : (_) => setState(() => jobs = n))),
          const Spacer(),
          Text('Timeout', style: TextStyle(color: p.dim, fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          for (final n in const [8, 15, 30]) Padding(padding: const EdgeInsets.only(left: 6), child: ChoiceChip(label: Text('${n}s'), selected: seconds == n, onSelected: busy ? null : (_) => setState(() => seconds = n))),
        ]),
        if (busy) Padding(padding: const EdgeInsets.only(top: 12), child: LinearProgressIndicator(color: p.accent, backgroundColor: alpha(p.dim, .2), borderRadius: BorderRadius.circular(6))),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: TextStyle(color: p.bad, height: 1.4))),
        if (res != null) ...[
          const SizedBox(height: 12),
          Text(res.isEmpty ? 'No results.' : '$good of ${res.length} worked', style: TextStyle(color: good > 0 ? p.good : p.warn, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          for (final r in res.take(60))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Icon(r.ok ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 18, color: r.ok ? p.good : p.bad),
                const SizedBox(width: 8),
                Expanded(child: Text(r.ok || r.error.isEmpty ? r.value : '${r.value}\n${r.error}', maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: r.ok ? p.text : p.dim))),
                if (r.ok) Pill('${r.ms} ms', color: pingColor(p, r.ms)),
                if (r.ok) TextButton(onPressed: () => _use(r), child: const Text('Use')),
              ]),
            ),
          if (res.length > 60) Text('Showing the first 60 of ${res.length}.', style: TextStyle(color: p.dim, fontSize: 12)),
          if (good > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: res.where((e) => e.ok).map((e) => e.value).join('\n')));
                  toast(context, 'Working hosts copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy working hosts'),
              ),
            ),
        ],
      ]),
    );
  }
}

// ───────── config check and payload preview (Validate, PayloadPreview) ─────────
class _CheckCard extends StatefulWidget {
  const _CheckCard();
  @override
  State<_CheckCard> createState() => _CheckCardState();
}

class _CheckCardState extends State<_CheckCard> {
  String? text;
  bool ok = true;
  bool mono = false;
  bool busy = false;

  Future<void> check() async {
    final s = context.read<AppState>();
    final r = _libConfig(s, forPing: false);
    if (r.json == null) {
      setState(() { text = r.error; ok = false; mono = false; });
      return;
    }
    setState(() => busy = true);
    final err = await s.bridge.validateConfig(r.json!);
    if (!mounted) return;
    setState(() {
      busy = false;
      mono = false;
      ok = err == null;
      text = err ?? 'The library accepts this config (${s.selected!.name}).';
    });
  }

  Future<void> preview() async {
    final s = context.read<AppState>();
    final r = _libConfig(s);
    if (r.json == null) {
      setState(() { text = r.error; ok = false; mono = false; });
      return;
    }
    if (s.selected!.p('payload').isEmpty) {
      setState(() { text = 'This server has no payload.'; ok = true; mono = false; });
      return;
    }
    setState(() => busy = true);
    try {
      final out = await s.bridge.payloadPreviewFor(r.json!);
      if (mounted) setState(() { text = out; ok = true; mono = true; });
    } catch (e) {
      if (mounted) setState(() { text = _msg(e); ok = false; mono = false; });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _ToolCard(
      icon: Icons.fact_check_rounded,
      title: 'Check selected server',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Asks the library whether it can run this config, without connecting, and shows exactly what the payload sends and how the reply is checked.', style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _btn(context, 'Check config', busy ? null : check),
          _btn(context, 'Preview payload', busy ? null : preview),
        ]),
        if (text != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SelectableText(text!, style: TextStyle(color: ok ? (mono ? p.text : p.good) : p.bad, height: 1.45, fontSize: mono ? 12.5 : 14, fontFamily: mono ? 'monospace' : null)),
          ),
      ]),
    );
  }
}

// ───────── route explainer (ExplainRoute) ─────────
class _RouteCard extends StatefulWidget {
  const _RouteCard();
  @override
  State<_RouteCard> createState() => _RouteCardState();
}

class _RouteCardState extends State<_RouteCard> {
  final ctl = TextEditingController();
  String protocol = '';
  String? text;
  bool busy = false;

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final s = context.read<AppState>();
    final h = ctl.text.trim();
    if (h.isEmpty) return;
    if (!s.isOn) {
      setState(() => text = 'Connect first: the rules are checked in the running tunnel.');
      return;
    }
    setState(() => busy = true);
    final r = await s.explainRoute(h, protocol: protocol);
    if (mounted) setState(() { text = r ?? 'The tunnel could not answer.'; busy = false; });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _ToolCard(
      icon: Icons.alt_route_rounded,
      title: 'Route check',
      action: _btn(context, busy ? '…' : 'Explain', busy ? null : run),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: ctl, autocorrect: false, onSubmitted: (_) => run(), decoration: _field('news.example.com or 1.2.3.4:443')),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final e in const {'': 'Any', 'http': 'HTTP', 'tls': 'TLS', 'bittorrent': 'BitTorrent', 'ssh': 'SSH'}.entries)
            ChoiceChip(label: Text(e.value), selected: protocol == e.key, onSelected: (_) => setState(() => protocol = e.key)),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(text ?? 'Shows whether the running tunnel sends a destination through the server, direct or blocks it, and which rule decided.', style: TextStyle(color: text == null ? p.dim : p.accent, fontWeight: text == null ? FontWeight.w400 : FontWeight.w800, height: 1.45, fontSize: text == null ? 12.5 : 14)),
        ),
      ]),
    );
  }
}

// ───────── reachability (Probe) ─────────
class _ReachCard extends StatefulWidget {
  const _ReachCard();
  @override
  State<_ReachCard> createState() => _ReachCardState();
}

class _ReachCardState extends State<_ReachCard> {
  final ctl = TextEditingController(text: 'example.com:443');
  String? text;
  bool ok = true;
  bool busy = false;

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final s = context.read<AppState>();
    final t = ctl.text.trim();
    final r = _libConfig(s);
    if (r.json == null) {
      setState(() { text = r.error; ok = false; });
      return;
    }
    if (!RegExp(r'^[^\s]+:\d{1,5}$').hasMatch(t)) {
      setState(() { text = 'Write the target as host:port.'; ok = false; });
      return;
    }
    setState(() { busy = true; text = null; });
    final sw = Stopwatch()..start();
    try {
      await s.bridge.probe(r.json!, t);
      if (mounted) setState(() { ok = true; text = 'Reached $t through "${s.selected!.name}" in ${sw.elapsedMilliseconds} ms.'; });
    } catch (e) {
      if (mounted) setState(() { ok = false; text = _msg(e); });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _ToolCard(
      icon: Icons.lan_rounded,
      title: 'Reach a target',
      action: _btn(context, busy ? '…' : 'Test', busy ? null : run),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: ctl, autocorrect: false, onSubmitted: (_) => run(), decoration: _field('host:port')),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(text ?? 'Opens a connection to the target through the selected server and closes it again.', style: TextStyle(color: text == null ? p.dim : (ok ? p.good : p.bad), height: 1.45, fontSize: text == null ? 12.5 : 14)),
        ),
      ]),
    );
  }
}

// ───────── DNS (DoH through tunnel) ─────────
class _DnsCard extends StatefulWidget {
  const _DnsCard();
  @override
  State<_DnsCard> createState() => _DnsCardState();
}

class _DnsCardState extends State<_DnsCard> {
  final ctl = TextEditingController(text: 'example.com');
  String? text;
  bool busy = false;

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<void> run() async {
    final s = context.read<AppState>();
    setState(() => busy = true);
    final c = s.tunnelClient();
    try {
      final req = await c.getUrl(Uri.parse('https://1.1.1.1/dns-query?name=${Uri.encodeQueryComponent(ctl.text.trim())}&type=A'));
      req.headers.set('accept', 'application/dns-json');
      final j = jsonDecode(await (await req.close()).transform(utf8.decoder).join()) as Map<String, dynamic>;
      final ans = (j['Answer'] as List?)?.map((a) => (a as Map)['data']).join('\n');
      text = ans == null || ans.isEmpty ? 'No A records.' : ans;
    } catch (e) {
      text = 'Lookup failed: $e';
    } finally {
      c.close(force: true);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _ToolCard(
      icon: Icons.travel_explore_rounded,
      title: 'DNS lookup',
      action: _btn(context, busy ? '…' : 'Resolve', busy ? null : run),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: ctl, autocorrect: false, decoration: _field(null)),
        if (text != null) Padding(padding: const EdgeInsets.only(top: 10), child: SelectableText(text!, style: TextStyle(color: p.text, height: 1.5))),
      ]),
    );
  }
}

// ───────── library options ─────────
class _OptionsCard extends StatelessWidget {
  const _OptionsCard();
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _ToolCard(
      icon: Icons.tune_rounded,
      title: 'Library options',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Everything else the tunnel library can do: idle timeout, failover ordering by latency, WebSocket keepalive and headers, XHTTP tuning, payload reply checks and variables, SSH algorithms and double hop, proxy headers.', style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 10),
        _btn(context, 'Open', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LibraryOptionsPage()))),
      ]),
    );
  }
}

// ───────── export ─────────
class _ExportCard extends StatelessWidget {
  const _ExportCard();
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return _ToolCard(
      icon: Icons.ios_share_rounded,
      title: 'Export selected server',
      child: Wrap(spacing: 10, runSpacing: 10, children: [
        _btn(context, 'Copy link', () {
          final c = s.selected;
          if (c != null && c.locked) { toast(context, 'Locked configs cannot be exported.'); return; }
          final l = c == null ? null : LinkParser.toLink(c);
          if (l == null) { toast(context, c == null ? 'Select a server first.' : 'This profile cannot be shared as a link.'); return; }
          Clipboard.setData(ClipboardData(text: l));
          toast(context, 'Link copied');
        }),
        _btn(context, 'Copy V2-TUN JSON', () {
          final c = s.selected;
          if (c == null) { toast(context, 'Select a server first.'); return; }
          if (c.locked) { toast(context, 'Locked configs cannot be exported.'); return; }
          try {
            Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(s.configFor(c))));
            toast(context, 'Config copied');
          } catch (e) {
            toast(context, '$e');
          }
        }),
      ]),
    );
  }
}


// ───────── data usage ─────────
class _UsageCard extends StatelessWidget {
  const _UsageCard();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final now = DateTime.now();
    final days = [for (var i = 6; i >= 0; i--) now.subtract(Duration(days: i))];
    final vals = [for (final d in days) (s.usage[AppState.dayKey(d)] ?? [0, 0]).fold<int>(0, (a, b) => a + b)];
    final week = vals.fold<int>(0, (a, b) => a + b);
    final month = s.usage.entries.where((e) => e.key.startsWith(AppState.dayKey(now).substring(0, 7))).fold<int>(0, (a, e) => a + e.value[0] + e.value[1]);
    return _ToolCard(
      icon: Icons.bar_chart_rounded,
      title: 'Data usage',
      action: TextButton(onPressed: s.clearUsage, child: const Text('Reset')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(height: 90, width: double.infinity, child: CustomPaint(painter: _BarPainter(vals, p.accent, p.dim))),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [for (final d in days) Text(['M', 'T', 'W', 'T', 'F', 'S', 'S'][d.weekday - 1], style: TextStyle(color: p.dim, fontSize: 11))]),
        const SizedBox(height: 12),
        Text('Today ${fmtBytes(s.today[0] + s.today[1])}  ·  7 days ${fmtBytes(week)}  ·  Month ${fmtBytes(month)}', style: TextStyle(color: p.dim, fontSize: 12.5)),
      ]),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.v, this.c, this.dim);
  final List<int> v;
  final Color c, dim;
  @override
  void paint(Canvas canvas, Size s) {
    final mx = v.fold<int>(1, (a, b) => b > a ? b : a).toDouble();
    final w = s.width / v.length;
    for (var i = 0; i < v.length; i++) {
      final h = (v[i] / mx) * (s.height - 6) + 3;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(i * w + w * .22, s.height - h, w * .56, h), const Radius.circular(6));
      canvas.drawRRect(r, Paint()..color = i == v.length - 1 ? c : alpha(c, .45));
    }
  }

  @override
  bool shouldRepaint(_BarPainter o) => true;
}
