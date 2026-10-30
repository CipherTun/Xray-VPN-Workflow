import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import '../core/accents.dart';
import '../state/app_state.dart';
import 'import_page.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final set = s.settings;
    final perApp = set.get<String>('perAppMode');

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
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 40), children: [
                _Section('Appearance', [
                  _Row(
                    title: 'Theme',
                    trailing: SegmentedButton<int>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, selectedBackgroundColor: p.accentSoft, selectedForegroundColor: p.accent),
                      segments: const [ButtonSegment(value: 0, label: Text('Auto')), ButtonSegment(value: 1, label: Text('Light')), ButtonSegment(value: 2, label: Text('Dark'))],
                      selected: {set.get<int>('themeMode')},
                      onSelectionChanged: (v) => s.setSetting('themeMode', v.first),
                    ),
                  ),
                  _AccentPicker(),
                  _SliderRow(title: 'Glass blur', value: set.get<double>('blur'), min: 0, max: 40, onChanged: (v) => s.setSetting('blur', v)),
                  _SwitchRow('Haptic feedback', null, 'haptics'),
                ]),
                _Section('Tunnel', [
                  _ChoiceRow('Routing', 'routing', const {'global': 'Everything', 'bypassLan': 'Skip LAN', 'bypassLanAds': 'Skip LAN + ads'}),
                  _SwitchRow('Kill switch', 'Keep traffic blocked if the tunnel drops instead of falling back to the open network', 'killSwitch'),
                  _SwitchRow('Auto-reconnect', 'Retry up to 5 times when the connection drops', 'autoReconnect'),
                  _SwitchRow('Connect on launch', null, 'autoConnect'),
                  _SwitchRow('IPv6', 'Route IPv6 through the tunnel', 'ipv6'),
                  _ValueRow('MTU', 'mtu', number: true),
                  _ValueRow('Primary DNS', 'dns1'),
                  _ValueRow('Secondary DNS', 'dns2'),
                  _ChoiceRow('Per-app VPN', 'perAppMode', const {'off': 'All apps', 'exclude': 'Exclude apps', 'only': 'Only apps'}),
                  if (perApp != 'off')
                    _Row(
                      title: perApp == 'only' ? 'Apps using the VPN' : 'Apps bypassing the VPN',
                      subtitle: '${set.list('perApps').length} selected',
                      onTap: () => _appPicker(context),
                      trailing: const Icon(Icons.chevron_right_rounded),
                    ),
                ]),
                _Section('Stay connected', [
                  _ChoiceRow('Wake lock strength', 'wakeMode', const {'off': 'Off', 'balanced': 'CPU only', 'strong': 'CPU + Wi-Fi + watchdog'}),
                  _Row(
                    title: 'Allow unrestricted battery use',
                    subtitle: 'Stops Doze and app standby from pausing the tunnel',
                    onTap: () => s.bridge.requestIgnoreBattery().catchError((_) => toast(context, 'Not available on this device.')),
                    trailing: const Icon(Icons.battery_charging_full_rounded, size: 20),
                  ),
                  _SwitchRow('Start on boot', 'Reconnect after the phone restarts (needs VPN permission granted once)', 'bootStart'),
                  _SwitchRow('Smart connect', 'Test every server and pick the fastest on connect', 'smartConnect'),
                  _IntChoiceRow('Sleep timer', 'sleepTimer', const {0: 'Off', 30: '30 min', 60: '1 h', 120: '2 h', 240: '4 h'}),
                ]),
                _Section('Routing & DNS', [
                  _ChoiceRow('DNS provider', 'dnsPreset', const {'cloudflare': 'Cloudflare', 'google': 'Google', 'quad9': 'Quad9', 'adguard': 'AdGuard', 'custom': 'Custom'}),
                  _SwitchRow('Block QUIC (UDP 443)', 'Forces browsers onto TCP, which proxies handle better', 'blockQuic'),
                  _Row(
                    title: 'Custom rules',
                    subtitle: set.get<String>('customRules').trim().isEmpty ? 'e.g. direct domain:bank.com' : '${set.get<String>('customRules').trim().split('\n').length} line(s)',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _rulesDialog(context),
                  ),
                  _ValueRow('Daily data warning (MB, 0 = off)', 'dailyCapMb', number: true),
                  _ValueRow('Subscription refresh (hours)', 'subRefreshHours', number: true),
                ]),
                _Section('Security', [
                  _Row(
                    title: set.get<String>('pin').isEmpty ? 'Set app PIN' : 'Change or remove PIN',
                    subtitle: 'Ask for a PIN when XRay opens or returns from the background',
                    trailing: Icon(set.get<String>('pin').isEmpty ? Icons.lock_open_rounded : Icons.lock_rounded, size: 20),
                    onTap: () => _pinDialog(context),
                  ),
                  _Row(title: 'Import a config', subtitle: 'File, link or text', trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportPage()))),
                ]),
                _Section('Protocol', [
                  _SwitchRow('Traffic sniffing', 'Detect domains for smarter routing', 'sniffing'),
                  _SwitchRow('Multiplexing (Mux)', 'Share one connection between streams', 'mux'),
                  _SwitchRow('TLS fragmentation', 'Split the TLS hello to evade filtering', 'fragment'),
                  _SwitchRow('Allow insecure TLS', 'Skips certificate checks. Only for servers you control', 'allowInsecure'),
                  _ChoiceRow('Core log level', 'logLevel', const {'warning': 'Warning', 'info': 'Info', 'debug': 'Debug', 'none': 'Off'}),
                  _ValueRow('Local SOCKS port', 'socksPort', number: true),
                ]),
                _Section('SSH', [
                  _ValueRow('Keep-alive (seconds)', 'sshKeepAlive', number: true),
                  _Row(
                    title: 'Forget trusted host keys',
                    subtitle: 'You will be asked to trust each server again',
                    onTap: () {
                      s.ssh.forgetHostKeys(s.prefs);
                      toast(context, 'Host keys cleared');
                    },
                  ),
                ]),
                _Section('System', [
                  _Row(title: 'System VPN settings', subtitle: 'Turn on Always-on VPN and Block connections without VPN', onTap: () => s.bridge.openSystemVpnSettings().catchError((_) => toast(context, 'Not available on this device.')), trailing: const Icon(Icons.open_in_new_rounded, size: 19)),
                  _Row(title: 'Battery optimisation', subtitle: 'Allow XRay to run unrestricted in the background', onTap: () => s.bridge.openBatterySettings().catchError((_) => toast(context, 'Not available on this device.')), trailing: const Icon(Icons.open_in_new_rounded, size: 19)),
                  _Row(title: 'Reset settings', onTap: () => _confirmReset(context)),
                ]),
                _Section('About', [
                  _Row(title: 'XRay VPN', subtitle: 'io.surprise.vpn · 1.1.0'),
                  _Row(title: 'Device ID', subtitle: s.deviceCode, trailing: const Icon(Icons.copy_rounded, size: 19), onTap: () { Clipboard.setData(ClipboardData(text: s.deviceCode)); toast(context, 'Device ID copied'); }),
                  const _Row(title: 'Xray-core', subtitle: 'v26.10.21'),
                  const _Row(title: 'DartSSH2', subtitle: '4.1.0'),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

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
          if (n != null && n > 0) s.setSetting(k, n);
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
