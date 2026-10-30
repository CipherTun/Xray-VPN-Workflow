import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent));
  final state = await AppState.create();
  runApp(ChangeNotifierProvider.value(value: state, child: const XRayApp()));
  state.onAppStart();
}

class XRayApp extends StatelessWidget {
  const XRayApp({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return MaterialApp(
      title: 'XRay VPN',
      debugShowCheckedModeBanner: false,
      themeMode: s.themeMode,
      theme: buildTheme(Brightness.light, s.accentFor(Brightness.light)),
      darkTheme: buildTheme(Brightness.dark, s.accentFor(Brightness.dark)),
      home: const Shell(),
    );
  }
}
