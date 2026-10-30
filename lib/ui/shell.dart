import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'configs_page.dart';
import 'dashboard_page.dart';
import 'import_page.dart';
import 'lock_screen.dart';
import 'logs_page.dart';
import 'theme.dart';
import 'tools_page.dart';
import 'widgets.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _i = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => context.read<AppState>().onLifecycle(state);

  static const _items = [
    (Icons.space_dashboard_rounded, 'Dashboard'),
    (Icons.dns_rounded, 'Configs'),
    (Icons.terminal_rounded, 'Logs'),
    (Icons.handyman_rounded, 'Tools'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final st = context.watch<AppState>();
    if (st.appLocked) return const LockScreen();
    final link = st.pendingImport;
    if (link != null) {
      st.clearPendingImport();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImportPage(initialText: link)));
      });
    }
    return Scaffold(
      extendBody: true,
      body: Backdrop(
        child: SafeArea(
          bottom: false,
          child: IndexedStack(index: _i, children: const [DashboardPage(), ConfigsPage(), LogsPage(), ToolsPage()]),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Glass(
            radius: 30,
            padding: const EdgeInsets.all(6),
            child: Row(children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _i = i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: _i == i ? p.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: _i == i ? [BoxShadow(color: alpha(p.accent, .22), blurRadius: 18)] : null,
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_items[i].$1, size: 23, color: _i == i ? p.accent : p.dim),
                        const SizedBox(height: 3),
                        Text(_items[i].$2, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _i == i ? p.accent : p.dim)),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
