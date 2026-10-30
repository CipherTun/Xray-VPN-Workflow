import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String filter = 'all';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final items = s.logs.reversed.where((l) => filter == 'all' || l.level == filter).toList();
    String t(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
    Color lc(String l) => switch (l) { 'error' => p.bad, 'warn' => p.warn, _ => p.accent };

    return Column(children: [
      PageHeader('Logs', subtitle: '${s.logs.length} entries', actions: [
        RoundIconButton(
          icon: Icons.copy_all_rounded,
          tooltip: 'Copy',
          onTap: () {
            Clipboard.setData(ClipboardData(text: items.map((l) => '${t(l.time)} [${l.level}] ${l.message}').join('\n')));
            toast(context, 'Logs copied');
          },
        ),
        RoundIconButton(icon: Icons.delete_sweep_rounded, tooltip: 'Clear', onTap: s.clearLogs),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Row(children: [
          for (final f in const ['all', 'info', 'warn', 'error'])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f[0].toUpperCase() + f.substring(1)),
                selected: filter == f,
                showCheckmark: false,
                onSelected: (_) => setState(() => filter = f),
                selectedColor: p.accentSoft,
                backgroundColor: Colors.transparent,
                side: BorderSide(color: filter == f ? alpha(p.accent, .5) : p.stroke),
                labelStyle: TextStyle(color: filter == f ? p.accent : p.text, fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
            ),
        ]),
      ),
      Expanded(
        child: items.isEmpty
            ? const Center(child: EmptyState(icon: Icons.receipt_long_rounded, title: 'Nothing logged yet', body: 'Connection events and core output show up here.'))
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
                child: Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final l = items[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(width: 3, height: 15, margin: const EdgeInsets.only(top: 2, right: 8), decoration: BoxDecoration(color: lc(l.level), borderRadius: BorderRadius.circular(2))),
                          Text(t(l.time), style: GoogleFonts.jetBrainsMono(fontSize: 11.5, color: p.dim)),
                          const SizedBox(width: 8),
                          Expanded(child: SelectableText(l.message, style: GoogleFonts.jetBrainsMono(fontSize: 11.5, height: 1.35))),
                        ]),
                      );
                    },
                  ),
                ),
              ),
      ),
    ]);
  }
}
