import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Full-screen PIN gate shown while [AppState.appLocked] is true.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String pin = '';
  bool wrong = false;

  Future<void> _tap(String d) async {
    HapticFeedback.selectionClick();
    if (d == '<') {
      setState(() { if (pin.isNotEmpty) pin = pin.substring(0, pin.length - 1); wrong = false; });
      return;
    }
    if (pin.length >= 8) return;
    setState(() { pin += d; wrong = false; });
  }

  Future<void> _submit() async {
    final ok = await context.read<AppState>().unlock(pin);
    if (!ok && mounted) {
      HapticFeedback.heavyImpact();
      setState(() { wrong = true; pin = ''; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock_rounded, size: 40, color: p.accent),
            const SizedBox(height: 16),
            const Text('XRay is locked', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(wrong ? 'Wrong PIN, try again' : 'Enter your PIN', style: TextStyle(color: wrong ? p.bad : p.dim)),
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < (pin.isEmpty ? 4 : pin.length); i++)
                AnimatedContainer(duration: const Duration(milliseconds: 150), margin: const EdgeInsets.all(6), width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, color: i < pin.length ? p.accent : alpha(p.dim, .3))),
            ]),
            const SizedBox(height: 26),
            SizedBox(
              width: 290,
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                childAspectRatio: 1.35,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final k in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '<', '0', 'OK'])
                    Padding(
                      padding: const EdgeInsets.all(5),
                      child: Glass(
                        radius: 22,
                        padding: EdgeInsets.zero,
                        onTap: () => k == 'OK' ? _submit() : _tap(k),
                        child: Center(child: k == '<' ? const Icon(Icons.backspace_outlined) : Text(k, style: TextStyle(fontSize: k == 'OK' ? 16 : 22, fontWeight: FontWeight.w800, color: k == 'OK' ? p.accent : p.text))),
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
