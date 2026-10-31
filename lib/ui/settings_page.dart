import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import 'package:path_provider/path_provider.dart';

import '../core/accents.dart';
import '../core/models.dart';
import '../core/ssh_tunnel.dart';
import '../core/xray_config.dart';
import '../state/app_state.dart';
import 'import_page.dart';
import 'share_page.dart';
import 'theme.dart';
import 'widgets.dart';


part 'settings_categories.dart';

class _Cat {
  const _Cat(this.icon, this.title, this.subtitle, this.keywords, this.page);
  final IconData icon;
  final String title, subtitle, keywords;
  final Widget Function() page;
}

/// Settings home: searchable list of categories, each with its own page.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final set = s.settings;
    final rules = set.get<String>('customRules').split('\n').where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#')).length;
    final cats = <_Cat>[
      _Cat(Icons.palette_rounded, 'Appearance', 'Theme, accent colours, glass blur', 'theme dark light accent colour color blur haptic', () => const _AppearancePage()),
      _Cat(Icons.vpn_lock_rounded, 'Connection', 'Kill switch, reconnect, per-app VPN, timers', 'kill switch reconnect auto connect ipv6 mtu per app split sleep timer smart fastest', () => const _ConnectionPage()),
      _Cat(Icons.alt_route_rounded, 'Routing & rules', '$rules custom rule${rules == 1 ? '' : 's'} · ${set.get<String>('routing') == 'global' ? 'everything proxied' : 'smart bypass'}', 'routing rules domain geosite geoip bypass lan china iran russia block ads quic bittorrent geo files', () => const _RoutingPage()),
      _Cat(Icons.dns_rounded, 'DNS', '${set.get<String>('dnsPreset')}${set.get<bool>('dnsDoh') ? ' · DoH' : ''}${set.get<bool>('fakeDns') ? ' · FakeDNS' : ''}', 'dns doh fake hosts resolver cloudflare google quad9 adguard', () => const _DnsPage()),
      _Cat(Icons.bolt_rounded, 'Xray / V2Ray core', 'Mux, fragment, sockopt, failover, chain, JSON', 'xray v2ray core mux xudp fragment sniffing tcp fast open fingerprint utls failover balancer chain double hop json lan share port', () => const _XrayPage()),
      _Cat(Icons.terminal_rounded, 'SSH', 'Keep-alive, host keys, jump host, transports', 'ssh keepalive host key jump proxy tls sni payload cipher', () => const _SshPage()),
      _Cat(Icons.android_rounded, 'Android', 'Wake lock, battery, notification, network', 'android wake lock battery boot notification bypass underlying lan always on data saver diagnostics', () => const _AndroidPage()),
      _Cat(Icons.shield_rounded, 'Security & privacy', 'App PIN, screenshots, logs', 'security privacy pin lock screenshot secure logs wipe', () => const _SecurityPage()),
      _Cat(Icons.storage_rounded, 'Data & backup', 'Usage caps, subscriptions, settings backup', 'data usage cap subscription backup restore export import', () => const _DataPage()),
      _Cat(Icons.info_outline_rounded, 'About', 'Versions, device ID, reset', 'about version device id reset', () => const _AboutPage()),
    ];
    final shown = cats.where((c) => q.isEmpty || '${c.title} ${c.subtitle} ${c.keywords}'.toLowerCase().contains(q.toLowerCase())).toList();

    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_rounded)),
                const Text('Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
              child: TextField(
                onChanged: (v) => setState(() => q = v),
                decoration: InputDecoration(
                  hintText: 'Search settings (dns, mux, wake lock…)',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                ),
              ),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 40), children: [
                for (final c in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Glass(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => c.page())),
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(14)),
                          child: Icon(c.icon, color: p.accent, size: 22),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(c.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                            const SizedBox(height: 2),
                            Text(c.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.dim, fontSize: 12.5)),
                          ]),
                        ),
                        Icon(Icons.chevron_right_rounded, color: p.dim),
                      ]),
                    ),
                  ),
                if (shown.isEmpty) const EmptyState(icon: Icons.search_off_rounded, title: 'No match', body: 'Try another word.'),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Scaffold shared by every settings page.
class _SubPage extends StatelessWidget {
  const _SubPage(this.title, this.children, {this.actions = const []});
  final String title;
  final List<Widget> Function(BuildContext context) children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_rounded)),
                Expanded(child: Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5))),
                ...actions,
              ]),
            ),
            Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: children(context))),
          ]),
        ),
      ),
    );
  }
}

// ───────── dialogs and pickers ─────────

Future<void> _rulesDialog(BuildContext context) async {
  final s = context.read<AppState>();
  final ctl = TextEditingController(text: s.settings.get<String>('customRules'));
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Custom rules'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('One rule per line: proxy, direct or block, then domains or IPs.\nExamples:\ndirect domain:bank.com\nblock geosite:category-ads-all\nproxy ip:8.8.8.8', style: TextStyle(fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 10),
          TextField(controller: ctl, minLines: 5, maxLines: 8, autocorrect: false, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save'))],
    ),
  );
  if (r != null) s.setSetting('customRules', r);
}

Future<void> _pinDialog(BuildContext context) async {
  final s = context.read<AppState>();
  final has = s.settings.get<String>('pin').isNotEmpty;
  final a = TextEditingController(), b = TextEditingController();
  final ok = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(has ? 'Change or remove PIN' : 'Set app PIN'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: a, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, decoration: const InputDecoration(labelText: 'New PIN (4-8 digits)')),
        TextField(controller: b, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, decoration: const InputDecoration(labelText: 'Repeat PIN')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        if (has) TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Remove PIN')),
        FilledButton(onPressed: () => Navigator.pop(c, a.text == b.text && RegExp(r'^\d{4,8}$').hasMatch(a.text) ? a.text : null), child: const Text('Save')),
      ],
    ),
  );
  if (ok == null) return;
  await s.setPin(ok);
  if (context.mounted) toast(context, ok.isEmpty ? 'PIN removed' : 'PIN saved');
}

Future<void> _confirmReset(BuildContext context) async {
  final s = context.read<AppState>();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Reset settings?'),
      content: const Text('Your servers stay. Theme, tunnel and protocol options return to their defaults.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset'))],
    ),
  );
  if (ok == true) s.resetSettings();
}

Future<void> _appPicker(BuildContext context) async {
  final s = context.read<AppState>();
  final apps = await s.bridge.installedApps();
  if (!context.mounted) return;
  if (apps.isEmpty) {
    toast(context, 'App list is only available on Android.');
    return;
  }
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => ChangeNotifierProvider.value(value: s, child: _AppPickerSheet(apps)),
  );
}


class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(left: 6, bottom: 8), child: Text(title, style: TextStyle(color: p.accent, fontWeight: FontWeight.w800, fontSize: 13.5))),
        Glass(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: p.stroke),
              children[i],
            ],
          ]),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, this.subtitle, this.trailing, this.onTap});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.3))),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ]),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow(this.title, this.subtitle, this.k);
  final String title;
  final String? subtitle;
  final String k;
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return _Row(title: title, subtitle: subtitle, onTap: () => s.setSetting(k, !s.settings.get<bool>(k)), trailing: Switch(value: s.settings.get<bool>(k), onChanged: (v) => s.setSetting(k, v)));
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow(this.title, this.k, this.options);
  final String title, k;
  final Map<String, String> options;
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final cur = s.settings.get<String>(k);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in options.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: cur == e.key,
              showCheckmark: false,
              onSelected: (_) => s.setSetting(k, e.key),
              selectedColor: p.accentSoft,
              backgroundColor: Colors.transparent,
              side: BorderSide(color: cur == e.key ? alpha(p.accent, .5) : p.stroke),
              labelStyle: TextStyle(color: cur == e.key ? p.accent : p.text, fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
        ]),
      ]),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow(this.title, this.k, {this.number = false});
  final String title, k;
  final bool number;
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final v = s.settings.get<dynamic>(k).toString();
    return _Row(
      title: title,
      trailing: Text(v, style: TextStyle(color: p.accent, fontWeight: FontWeight.w800)),
      onTap: () async {
        final ctl = TextEditingController(text: v);
        final r = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(title),
            content: TextField(controller: ctl, autofocus: true, keyboardType: number ? TextInputType.number : TextInputType.text),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save'))],
          ),
        );
        if (r == null || r.isEmpty) return;
        if (number) {
          final n = int.tryParse(r);
          // Zero is a real value for caps, keep-alive and "automatic" ports; ports and sizes must stay positive.
          const zeroOk = {'dailyCapMb', 'monthlyCapMb', 'tcpKeepAlive', 'sshLocalPort'};
          if (n != null && (n > 0 || (n == 0 && zeroOk.contains(k)))) s.setSetting(k, n);
        } else {
          s.setSetting(k, r);
        }
      },
    );
  }
}

class _IntChoiceRow extends StatelessWidget {
  const _IntChoiceRow(this.title, this.k, this.options);
  final String title, k;
  final Map<int, String> options;
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final cur = s.settings.get<int>(k);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in options.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: cur == e.key,
              showCheckmark: false,
              onSelected: (_) => s.setSetting(k, e.key),
              selectedColor: p.accentSoft,
              backgroundColor: Colors.transparent,
              side: BorderSide(color: cur == e.key ? alpha(p.accent, .5) : p.stroke),
              labelStyle: TextStyle(color: cur == e.key ? p.accent : p.text, fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
        ]),
      ]),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.title, required this.value, required this.min, required this.max, required this.onChanged});
  final String title;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Slider(value: value, min: min, max: max, onChanged: onChanged),
        ]),
      );
}

class _AccentPicker extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final cur = s.settings.get<int>('accent');
    Widget dot(Color c, bool sel, VoidCallback on, {Widget? child}) => GestureDetector(
          onTap: on,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: sel ? p.text : Colors.transparent, width: 2)),
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: c, border: Border.all(color: alpha(Colors.white, .25))),
              child: child,
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Accent', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < Accents.presets.length; i++) dot(Accents.presets[i].color, cur == i, () => s.setSetting('accent', i)),
          Container(
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: cur == Accents.customIndex ? p.text : Colors.transparent, width: 2)),
            child: GestureDetector(
              onTap: () => _pickCustom(context),
              child: Container(
                decoration: const BoxDecoration(shape: BoxShape.circle, gradient: SweepGradient(colors: [Color(0xFFFF5F6D), Color(0xFFFFC371), Color(0xFF5BD6A0), Color(0xFF4FA3FF), Color(0xFFB77CFF), Color(0xFFFF5F6D)])),
                child: const Icon(Icons.colorize_rounded, size: 18, color: Colors.white),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Text(cur == Accents.customIndex ? 'Custom' : Accents.presets[cur].name, style: TextStyle(color: p.dim, fontSize: 12.5)),
      ]),
    );
  }

  Future<void> _pickCustom(BuildContext context) async {
    final s = context.read<AppState>();
    var color = Color(s.settings.get<int>('customAccent'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Custom accent'),
        content: SingleChildScrollView(
          child: ColorPicker(pickerColor: color, onColorChanged: (v) => color = v, enableAlpha: false, labelTypes: const [], pickerAreaHeightPercent: .7, hexInputBar: true),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Use colour'))],
      ),
    );
    if (ok == true) {
      s.setSetting('customAccent', color.toARGB32());
      s.setSetting('accent', Accents.customIndex);
    }
  }
}

class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet(this.apps);
  final List<Map<String, String>> apps;
  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final chosen = s.settings.list('perApps').toSet();
    final list = widget.apps.where((a) => (a['label'] ?? '').toLowerCase().contains(q.toLowerCase())).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .85,
      maxChildSize: .95,
      builder: (_, ctl) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: InputDecoration(hintText: 'Search apps', prefixIcon: const Icon(Icons.search_rounded), filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: ctl,
            itemCount: list.length,
            itemBuilder: (_, i) {
              final a = list[i];
              final id = a['package']!;
              return CheckboxListTile(
                value: chosen.contains(id),
                title: Text(a['label'] ?? id, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(id, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
                onChanged: (v) {
                  final next = {...chosen};
                  v == true ? next.add(id) : next.remove(id);
                  s.setSetting('perApps', next.toList());
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
