import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/link_parser.dart';
import '../core/xray_config.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const PageHeader('Tools', subtitle: 'Checks run through the tunnel when connected'),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 120), children: const [
          _IpCard(),
          SizedBox(height: 12),
          _SpeedCard(),
          SizedBox(height: 12),
          _LatencyCard(),
          SizedBox(height: 12),
          _UsageCard(),
          SizedBox(height: 12),
          _DnsCard(),
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

// ───────── speed ─────────
class _SpeedCard extends StatefulWidget {
  const _SpeedCard();
  @override
  State<_SpeedCard> createState() => _SpeedCardState();
}

class _SpeedCardState extends State<_SpeedCard> {
  double? mbps;
  double progress = 0;
  bool busy = false;
  String? err;

  Future<void> run() async {
    final s = context.read<AppState>();
    setState(() { busy = true; mbps = null; err = null; progress = 0; });
    const total = 25000000;
    final c = s.tunnelClient();
    final sw = Stopwatch()..start();
    var got = 0;
    try {
      final r = await (await c.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=$total'))).close();
      await for (final chunk in r) {
        got += chunk.length;
        if (!mounted) return;
        setState(() { progress = got / total; mbps = got * 8 / 1e6 / (sw.elapsedMilliseconds / 1000 + .001); });
      }
    } catch (e) {
      err = '$e';
    } finally {
      c.close(force: true);
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
        Text(err != null ? 'Test failed: $err' : mbps == null ? 'Downloads 25 MB and measures throughput.' : '${mbps!.toStringAsFixed(1)} Mbit/s', style: TextStyle(fontSize: err == null && mbps != null ? 26 : 14, fontWeight: FontWeight.w800, color: err != null ? p.bad : (mbps == null ? p.dim : p.text))),
        if (busy) Padding(padding: const EdgeInsets.only(top: 10), child: LinearProgressIndicator(value: progress, color: p.accent, backgroundColor: alpha(p.dim, .2), borderRadius: BorderRadius.circular(6))),
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
      await s.pingOne(sel);
      lines.add('Server (TCP): ${sel.pingMs! < 0 ? 'timeout' : '${sel.pingMs} ms'}');
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
      child: Text(text ?? 'Round-trip time to the selected server and through the tunnel.', style: TextStyle(color: text == null ? p.dim : p.text, height: 1.5)),
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
        TextField(controller: ctl, autocorrect: false, decoration: InputDecoration(isDense: true, filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none))),
        if (text != null) Padding(padding: const EdgeInsets.only(top: 10), child: SelectableText(text!, style: TextStyle(color: p.text, height: 1.5))),
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
        _btn(context, 'Copy Xray JSON', () {
          final c = s.selected;
          if (c == null) { toast(context, 'Select a server first.'); return; }
          if (c.locked) { toast(context, 'Locked configs cannot be exported.'); return; }
          Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(buildXrayConfig(c, s.settings, sshSocksPort: s.settings.get<int>('socksPort') + 2))));
          toast(context, 'Config copied');
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
