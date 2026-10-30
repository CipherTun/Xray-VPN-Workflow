import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'configs_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final sel = s.selected;

    final (headline, sub) = switch (s.status) {
      VpnStatus.connected => ('Protected', fmtDuration(s.uptime)),
      VpnStatus.connecting => ('Securing connection', 'Starting the tunnel'),
      VpnStatus.disconnecting => ('Disconnecting', 'One moment'),
      VpnStatus.error => ('Could not connect', s.lastError ?? 'Check Logs for details'),
      VpnStatus.disconnected => ('Not protected', sel == null ? 'Add a server to begin' : 'Tap the dial to connect'),
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 120),
      children: [
        Row(children: [
          Expanded(
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), gradient: LinearGradient(colors: [p.accent, p.steel])),
                child: Icon(Icons.bolt_rounded, color: p.onAccent, size: 21),
              ),
              const SizedBox(width: 10),
              const Text('XRay', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -.6)),
            ]),
          ),
          RoundIconButton(
            icon: Icons.tune_rounded,
            tooltip: 'Settings',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ]),
        const SizedBox(height: 22),
        Center(child: ConnectOrb(status: s.status, onTap: s.toggle)),
        const SizedBox(height: 18),
        Center(child: Text(headline, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.6))),
        const SizedBox(height: 4),
        Center(
          child: Text(
            sub,
            textAlign: TextAlign.center,
            style: s.status == VpnStatus.connected
                ? GoogleFonts.jetBrainsMono(color: p.accent, fontSize: 16, fontWeight: FontWeight.w600)
                : TextStyle(color: s.status == VpnStatus.error ? p.bad : p.dim, fontSize: 14),
          ),
        ),
        const SizedBox(height: 22),
        if (sel != null && (sel.note.isNotEmpty || expiryText(sel) != null))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Glass(
              tint: sel.expired ? alpha(p.bad, .14) : null,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(sel.expired ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 18, color: sel.expired ? p.bad : p.accent),
                  const SizedBox(width: 8),
                  Expanded(child: Text(sel.author.isEmpty ? 'Message' : 'From ${sel.author}', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 12.5))),
                  if (expiryText(sel) != null) Pill(expiryText(sel)!, color: sel.expired ? p.bad : p.warn, icon: Icons.timer_outlined),
                ]),
                if (sel.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(sel.note, style: const TextStyle(height: 1.4, fontSize: 14))),
                if (sel.expired) Padding(padding: const EdgeInsets.only(top: 8), child: Text('This config has expired. Ask the sender for a new one.', style: TextStyle(color: p.bad, fontSize: 13))),
              ]),
            ),
          ),
        if (s.capExceeded)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Glass(tint: alpha(p.warn, .14), child: Row(children: [Icon(Icons.data_usage_rounded, color: p.warn), const SizedBox(width: 10), const Expanded(child: Text('Daily data limit reached'))])),
          ),
        if (s.sleepAt != null && s.isOn)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Glass(child: Row(children: [Icon(Icons.bedtime_outlined, color: p.accent), const SizedBox(width: 10), Expanded(child: Text('Disconnects in ${fmtDuration(s.sleepAt!.difference(DateTime.now()).isNegative ? Duration.zero : s.sleepAt!.difference(DateTime.now()))}'))])),
          ),
        Glass(
          onTap: () => showServerPicker(context),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(14)),
              child: Icon(sel?.proto == Proto.ssh ? Icons.terminal_rounded : Icons.public_rounded, color: p.accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(sel?.name ?? 'No server selected', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 2),
                Text(sel == null ? 'Tap to add one' : (sel.locked ? '${sel.proto.label}  ·  Locked config' : '${sel.proto.label}  ·  ${sel.host}:${sel.port}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.dim, fontSize: 12.5)),
              ]),
            ),
            if (sel?.pingMs != null) Pill(sel!.pingMs! < 0 ? 'Timeout' : '${sel.pingMs} ms', color: pingColor(p, sel.pingMs)),
            const SizedBox(width: 6),
            Icon(Icons.unfold_more_rounded, color: p.dim),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _Stat(icon: Icons.south_rounded, label: 'Download', value: fmtRate(s.rxBps), foot: fmtBytes(s.rxTotal))),
          const SizedBox(width: 12),
          Expanded(child: _Stat(icon: Icons.north_rounded, label: 'Upload', value: fmtRate(s.txBps), foot: fmtBytes(s.txTotal))),
        ]),
        const SizedBox(height: 12),
        Glass(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Throughput', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 13)),
              const Spacer(),
              Text('last 48 s', style: TextStyle(color: p.dim, fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            Sparkline(s.rxHistory),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Routing', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (v, l) in const [('global', 'Everything'), ('bypassLan', 'Skip local network'), ('bypassLanAds', 'Skip local, block ads')])
                ChoiceChip(
                  label: Text(l),
                  selected: s.settings.get<String>('routing') == v,
                  onSelected: (_) {
                    s.setSetting('routing', v);
                    if (s.isOn) toast(context, 'Routing changes apply the next time you connect.');
                  },
                  showCheckmark: false,
                  selectedColor: p.accentSoft,
                  labelStyle: TextStyle(color: s.settings.get<String>('routing') == v ? p.accent : p.text, fontWeight: FontWeight.w700, fontSize: 12.5),
                  side: BorderSide(color: s.settings.get<String>('routing') == v ? alpha(p.accent, .5) : p.stroke),
                  backgroundColor: Colors.transparent,
                ),
            ]),
          ]),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value, required this.foot});
  final IconData icon;
  final String label, value, foot;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Glass(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 16, color: p.accent),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ]),
        const SizedBox(height: 10),
        Text(value, style: GoogleFonts.jetBrainsMono(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('Total $foot', style: TextStyle(color: p.dim, fontSize: 11.5)),
      ]),
    );
  }
}
