import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

Color alpha(Color c, double o) => c.withAlpha((o * 255).round().clamp(0, 255));

/// Design tokens. Greyish-blue + black base, one soft accent.
class XPalette {
  XPalette(this.brightness, this.accent);
  final Brightness brightness;
  final Color accent;

  bool get dark => brightness == Brightness.dark;

  Color get bgTop => dark ? const Color(0xFF090D13) : const Color(0xFFEBF1F7);
  Color get bgBottom => dark ? const Color(0xFF17212F) : const Color(0xFFD2DDE9);
  Color get steel => dark ? const Color(0xFF3F5878) : const Color(0xFF8FA6C2); // greyish blue
  Color get glass => dark ? alpha(Colors.white, .055) : alpha(Colors.white, .52);
  Color get glassHi => dark ? alpha(Colors.white, .11) : alpha(Colors.white, .85);
  Color get stroke => dark ? alpha(Colors.white, .10) : alpha(Colors.white, .75);
  Color get text => dark ? const Color(0xFFE9EFF6) : const Color(0xFF0E1722);
  Color get dim => dark ? const Color(0xFF8DA0B6) : const Color(0xFF55667B);
  Color get accentSoft => alpha(accent, dark ? .18 : .16);
  Color get onAccent => accent.computeLuminance() > .45 ? const Color(0xFF0A1118) : Colors.white;
  Color get good => const Color(0xFF5FC48D);
  Color get warn => const Color(0xFFE7B452);
  Color get bad => const Color(0xFFE5697A);

  static XPalette of(BuildContext c) {
    final s = c.watch<AppState>();
    final b = Theme.of(c).brightness;
    return XPalette(b, s.accentFor(b));
  }
}

extension PalX on BuildContext {
  XPalette get pal => XPalette.of(this);
}

ThemeData buildTheme(Brightness b, Color accent) {
  final p = XPalette(b, accent);
  final base = ThemeData(brightness: b, useMaterial3: true);
  final tt = GoogleFonts.manropeTextTheme(base.textTheme).apply(bodyColor: p.text, displayColor: p.text);
  return base.copyWith(
    colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(primary: accent),
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: tt,
    splashFactory: InkSparkle.splashFactory,
    dividerColor: p.stroke,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.dim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : alpha(p.dim, .25)),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(activeTrackColor: accent, thumbColor: accent, inactiveTrackColor: alpha(p.dim, .25)),
    dialogTheme: DialogThemeData(
      backgroundColor: p.dark ? const Color(0xFF131C28) : const Color(0xFFF2F6FA),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.dark ? const Color(0xFF111924) : const Color(0xFFF1F5F9),
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.dark ? const Color(0xFF1C2735) : const Color(0xFF16202C),
      contentTextStyle: GoogleFonts.manrope(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
