import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

String fmtBytes(num b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble(), i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

String fmtRate(num bps) => '${fmtBytes(bps)}/s';

String fmtDuration(Duration d) {
  String t(int n) => n.toString().padLeft(2, '0');
  return '${t(d.inHours)}:${t(d.inMinutes % 60)}:${t(d.inSeconds % 60)}';
}

/// Page background: vertical steel gradient with two soft accent blooms.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.child});
  final Widget child;

  Widget _bloom(Color c, double size, double a) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [alpha(c, a), alpha(c, 0)]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.bgTop, p.bgBottom]),
          ),
        ),
        Positioned(top: -140, right: -120, child: _bloom(p.accent, 440, p.dark ? .26 : .30)),
        Positioned(bottom: 40, left: -180, child: _bloom(p.steel, 520, p.dark ? .34 : .40)),
        child,
      ],
    );
  }
}

/// Frosted glass surface. Blur radius comes from the user's setting.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.onTap,
    this.onLongPress,
    this.tint,
  });
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap, onLongPress;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final blur = context.select<AppState, double>((s) => s.settings.get<double>('blur'));
    final br = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: br,
            color: tint ?? p.glass,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [alpha(Colors.white, p.dark ? .07 : .35), alpha(Colors.white, 0)],
            ),
            border: Border.all(color: p.stroke),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              borderRadius: br,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color, this.icon});
  final String label;
  final Color? color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final c = color ?? p.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: alpha(c, .16), borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: c), const SizedBox(width: 4)],
        Text(label, style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// Short countdown for a profile's expiry, or null when it never expires.
String? expiryText(ServerConfig c) {
  final e = c.effectiveExpiry;
  if (e == null) return null;
  final d = e.difference(DateTime.now().toUtc());
  if (d.isNegative) return 'Expired';
  if (d.inDays >= 1) return '${d.inDays}d left';
  if (d.inHours >= 1) return '${d.inHours}h left';
  return '${d.inMinutes}m left';
}

/// Remaining data of a limited config, or null.
String? dataLeftText(ServerConfig c) {
  final left = c.dataLeftBytes;
  return left == null ? null : '${fmtBytes(left)} left';
}

Color pingColor(XPalette p, int? ms) {
  if (ms == null) return p.dim;
  if (ms < 0) return p.bad;
  if (ms < 150) return p.good;
  if (ms < 350) return p.warn;
  return p.bad;
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.subtitle, this.actions = const []});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 14, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -.8)),
            if (subtitle != null) Text(subtitle!, style: TextStyle(color: p.dim, fontSize: 13)),
          ]),
        ),
        ...actions,
      ]),
    );
  }
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.onTap, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: tooltip ?? '',
        child: Glass(
          radius: 99,
          padding: const EdgeInsets.all(11),
          onTap: onTap,
          child: Icon(icon, size: 21, color: p.text),
        ),
      ),
    );
  }
}

/// The signature element: a dial of ticks around a lens-like core.
class ConnectOrb extends StatefulWidget {
  const ConnectOrb({super.key, required this.status, required this.onTap, this.size = 270});
  final VpnStatus status;
  final VoidCallback onTap;
  final double size;
  @override
  State<ConnectOrb> createState() => _ConnectOrbState();
}

class _ConnectOrbState extends State<ConnectOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final on = widget.status == VpnStatus.connected;
    final busy = widget.status == VpnStatus.connecting || widget.status == VpnStatus.disconnecting;
    final err = widget.status == VpnStatus.error;
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(alignment: Alignment.center, children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) => CustomPaint(
                size: Size.square(widget.size),
                painter: _OrbPainter(_c.value, on, busy, err, p),
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Icon(
              on ? Icons.shield_rounded : Icons.power_settings_new_rounded,
              key: ValueKey(on),
              size: widget.size * .21,
              color: on ? p.onAccent : p.text,
            ),
          ),
        ]),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.t, this.on, this.busy, this.err, this.p);
  final double t;
  final bool on, busy, err;
  final XPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final ctr = size.center(Offset.zero);
    final r = size.width / 2;
    final hue = err ? p.bad : p.accent;

    // Glow
    final breathe = .5 + .5 * math.sin(t * 2 * math.pi * 2);
    final glowA = on ? .30 + .12 * breathe : (busy ? .22 : .10);
    canvas.drawCircle(
      ctr,
      r * .95,
      Paint()
        ..shader = RadialGradient(colors: [alpha(hue, glowA * 1.6), alpha(hue, 0)]).createShader(Rect.fromCircle(center: ctr, radius: r)),
    );

    // Tick dial
    const n = 72;
    final head = t * 2 * math.pi * (busy ? 2 : 1);
    for (var i = 0; i < n; i++) {
      final a = i / n * 2 * math.pi - math.pi / 2;
      var lit = 0.0;
      if (on) {
        final d = ((a - head + 4 * math.pi) % (2 * math.pi)) / (2 * math.pi);
        lit = .55 + .45 * (1 - d);
      } else if (busy) {
        final d = ((head - a + 4 * math.pi) % (2 * math.pi)) / (2 * math.pi);
        lit = d < .28 ? 1 - d / .28 : 0;
      }
      final major = i % 6 == 0;
      final r1 = r * (major ? .80 : .84), r2 = r * .91;
      final color = lit > 0 ? alpha(hue, .25 + .75 * lit) : alpha(p.dim, major ? .45 : .22);
      canvas.drawLine(
        ctr + Offset(math.cos(a), math.sin(a)) * r1,
        ctr + Offset(math.cos(a), math.sin(a)) * r2,
        Paint()
          ..color = color
          ..strokeWidth = major ? 2.4 : 1.6
          ..strokeCap = StrokeCap.round,
      );
    }

    // Outer hairline
    canvas.drawCircle(ctr, r * .97, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = alpha(p.dim, .18));

    // Core lens
    final core = r * .60;
    final rect = Rect.fromCircle(center: ctr, radius: core);
    final Gradient fill = on
        ? RadialGradient(center: const Alignment(-.35, -.4), radius: 1.1, colors: [Color.lerp(hue, Colors.white, .30)!, hue, Color.lerp(hue, Colors.black, .35)!])
        : RadialGradient(
            center: const Alignment(-.35, -.4),
            radius: 1.1,
            colors: p.dark
                ? [const Color(0xFF34455B), const Color(0xFF1B2636), const Color(0xFF0E141D)]
                : [Colors.white, const Color(0xFFDCE5EF), const Color(0xFFB9C8DA)],
          );
    canvas.drawShadow(Path()..addOval(rect), alpha(on ? hue : Colors.black, .5), 18, true);
    canvas.drawCircle(ctr, core, Paint()..shader = fill.createShader(rect));
    canvas.drawCircle(
      ctr,
      core,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = SweepGradient(colors: [alpha(Colors.white, .5), alpha(Colors.white, .02), alpha(Colors.white, .3)]).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter o) => o.t != t || o.on != on || o.busy != busy || o.err != err || o.p.accent != p.accent || o.p.dark != p.dark;
}

class Sparkline extends StatelessWidget {
  const Sparkline(this.values, {super.key, this.height = 64});
  final List<double> values;
  final double height;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SizedBox(height: height, width: double.infinity, child: CustomPaint(painter: _SparkPainter(values, p.accent, p.dim)));
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.v, this.c, this.base);
  final List<double> v;
  final Color c, base;
  @override
  void paint(Canvas canvas, Size s) {
    final mx = math.max(v.fold<double>(0, math.max), 1024);
    final pts = [for (var i = 0; i < v.length; i++) Offset(i / (v.length - 1) * s.width, s.height - 4 - (v[i] / mx) * (s.height - 10))];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final m = (pts[i - 1] + pts[i]) / 2;
      path.quadraticBezierTo(pts[i - 1].dx, pts[i - 1].dy, m.dx, m.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    final fill = Path.from(path)..lineTo(s.width, s.height)..lineTo(0, s.height)..close();
    canvas.drawPath(fill, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [alpha(c, .35), alpha(c, 0)]).createShader(Offset.zero & s));
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.2..strokeCap = StrokeCap.round..color = c);
  }

  @override
  bool shouldRepaint(_SparkPainter o) => true;
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title, body;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44, color: p.dim),
        const SizedBox(height: 14),
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(body, textAlign: TextAlign.center, style: TextStyle(color: p.dim, height: 1.4)),
        if (action != null) ...[const SizedBox(height: 18), action!],
      ]),
    );
  }
}

void toast(BuildContext c, String m) =>
    ScaffoldMessenger.of(c)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));
