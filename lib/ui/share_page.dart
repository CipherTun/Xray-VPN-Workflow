import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/config_package.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Share one or more profiles the way provider-style tunnel apps do:
/// custom message, expiry, lock, password and device binding.
class SharePage extends StatefulWidget {
  const SharePage({super.key, this.initial, this.selectAll = false});
  final ServerConfig? initial;
  final bool selectAll;
  @override
  State<SharePage> createState() => _SharePageState();
}

enum _Expiry { never, date, days }

class _SharePageState extends State<SharePage> {
  final title = TextEditingController();
  final note = TextEditingController();
  final author = TextEditingController();
  final password = TextEditingController();
  final device = TextEditingController();
  late final Set<String> chosen = {if (widget.initial != null) widget.initial!.id};
  _Expiry expiry = _Expiry.never;
  DateTime? date;
  int days = 7;
  bool lock = true;
  bool reshare = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.selectAll) chosen.addAll(context.read<AppState>().configs.where((c) => c.allowShare).map((c) => c.id));
  }

  @override
  void dispose() {
    for (final c in [title, note, author, password, device]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final s = context.read<AppState>();
    final list = s.configs.where((c) => chosen.contains(c.id)).toList();
    if (list.isEmpty) return toast(context, 'Pick at least one server to share.');
    if (list.any((c) => !c.allowShare)) return toast(context, 'One of these configs may not be re-shared.');
    if (expiry == _Expiry.date && date == null) return toast(context, 'Choose an expiry date.');
    setState(() => busy = true);
    try {
      final meta = ShareMeta(
        title: title.text.trim(),
        note: note.text.trim(),
        author: author.text.trim(),
        expiresAt: expiry == _Expiry.date ? DateTime(date!.year, date!.month, date!.day, 23, 59, 59).toUtc() : null,
        validDays: expiry == _Expiry.days ? days : null,
        locked: lock,
        allowReshare: reshare,
        deviceHash: device.text.trim().isEmpty ? null : await ConfigPackage.hashDeviceId(device.text),
      );
      // Keep the strictest limits already on a profile that was itself imported.
      final env = await ConfigPackage.encode(meta, list, password: password.text);
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _ResultSheet(envelope: env, name: meta.title.isEmpty ? (list.length == 1 ? list.first.name : 'xray-configs') : meta.title, hasPassword: password.text.isNotEmpty),
      );
    } catch (e) {
      if (mounted) toast(context, 'Could not create the share file: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {int lines = 1, int? max, bool obscure = false, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          minLines: lines,
          maxLines: lines,
          maxLength: max,
          obscureText: obscure,
          autocorrect: false,
          decoration: InputDecoration(labelText: label, hintText: hint, filled: true, counterText: '', border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
        ),
      );

  Widget _card(String title, IconData icon, List<Widget> children) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Glass(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: p.accent),
            const SizedBox(width: 8),
            Text(title, style: TextStyle(color: p.accent, fontWeight: FontWeight.w800, fontSize: 13.5)),
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_rounded)),
                const Text('Share config', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5)),
              ]),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 30), children: [
                _card('What to share', Icons.dns_rounded, [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final c in s.configs)
                      FilterChip(
                        label: Text(c.name, overflow: TextOverflow.ellipsis),
                        selected: chosen.contains(c.id),
                        onSelected: c.allowShare ? (v) => setState(() => v ? chosen.add(c.id) : chosen.remove(c.id)) : null,
                        avatar: c.allowShare ? null : const Icon(Icons.lock_rounded, size: 15),
                      ),
                  ]),
                ]),
                _card('Message for the receiver', Icons.chat_bubble_outline_rounded, [
                  _field(title, 'Title (replaces the server name)', max: 60),
                  _field(note, 'Note shown when they import it', lines: 3, max: 400, hint: 'Welcome! Valid for 30 days. Support: …'),
                  _field(author, 'From (your name or brand)', max: 40),
                ]),
                _card('Expiry', Icons.timer_outlined, [
                  SegmentedButton<_Expiry>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(selectedBackgroundColor: p.accentSoft, selectedForegroundColor: p.accent),
                    segments: const [
                      ButtonSegment(value: _Expiry.never, label: Text('Never')),
                      ButtonSegment(value: _Expiry.date, label: Text('On a date')),
                      ButtonSegment(value: _Expiry.days, label: Text('After import')),
                    ],
                    selected: {expiry},
                    onSelectionChanged: (v) => setState(() => expiry = v.first),
                  ),
                  if (expiry == _Expiry.date)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.event_rounded),
                        label: Text(date == null ? 'Choose date' : date!.toString().substring(0, 10)),
                        onPressed: () async {
                          final d = await showDatePicker(context: context, initialDate: date ?? DateTime.now().add(const Duration(days: 30)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
                          if (d != null) setState(() => date = d);
                        },
                      ),
                    ),
                  if (expiry == _Expiry.days) ...[
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, children: [
                      for (final d in const [1, 3, 7, 30, 90, 365])
                        ChoiceChip(label: Text(d == 365 ? '1 year' : '$d day${d > 1 ? 's' : ''}'), selected: days == d, onSelected: (_) => setState(() => days = d)),
                    ]),
                    const SizedBox(height: 6),
                    Text('The countdown starts when the receiver imports the config.', style: TextStyle(color: p.dim, fontSize: 12.5)),
                  ],
                ]),
                _card('Protection', Icons.shield_outlined, [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Lock config', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Hide the server address and credentials, and block editing and exporting'),
                    value: lock,
                    onChanged: (v) => setState(() => lock = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow re-sharing', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Let the receiver pass it on to others'),
                    value: reshare,
                    onChanged: (v) => setState(() => reshare = v),
                  ),
                  const SizedBox(height: 6),
                  _field(password, 'Password (optional)', obscure: true, hint: 'Required to open the file'),
                  _field(device, 'Lock to a device (optional)', hint: 'Receiver\'s Device ID, e.g. A1B2-C3D4-E5F6'),
                  Text(
                    'A password makes the file unreadable without it. Lock and device binding stop casual copying, but the app must give the credentials to the VPN core to connect, so a determined person on a rooted phone can still recover them. Only share with people you trust.',
                    style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.4),
                  ),
                ]),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: busy ? null : _create,
                  icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.ios_share_rounded),
                  label: Text(busy ? 'Encrypting…' : 'Create share file', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ResultSheet extends StatelessWidget {
  const _ResultSheet({required this.envelope, required this.name, required this.hasPassword});
  final String envelope, name;
  final bool hasPassword;

  Future<void> _shareFile(BuildContext context) async {
    final dir = await getTemporaryDirectory();
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final f = File('${dir.path}/$safe.xrcfg');
    await f.writeAsString(envelope);
    await Share.shareXFiles([XFile(f.path, mimeType: 'application/json')], subject: 'XRay VPN config');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final link = ConfigPackage.toLink(envelope);
    final qrOk = link.length < 2000;
    return ListView(padding: const EdgeInsets.fromLTRB(22, 20, 22, 28), shrinkWrap: true, children: [
      const Text('Ready to share', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(hasPassword ? 'Encrypted with your password. Tell the receiver the password separately.' : 'Encrypted. The receiver opens it in XRay VPN → Configs → Add → Import config.', style: TextStyle(color: p.dim, height: 1.4)),
      const SizedBox(height: 16),
      if (qrOk)
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
            child: QrImageView(data: link, size: 210, errorCorrectionLevel: QrErrorCorrectLevel.L),
          ),
        )
      else
        Text('This config is too large for a QR code. Use the file or link instead.', style: TextStyle(color: p.dim)),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () => _shareFile(context),
            icon: const Icon(Icons.attach_file_rounded),
            label: const Text('Share file'),
            style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent, padding: const EdgeInsets.symmetric(vertical: 14)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              toast(context, 'Link copied');
            },
            icon: const Icon(Icons.link_rounded),
            label: const Text('Copy link'),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      TextButton.icon(
        onPressed: () => Share.share(link),
        icon: const Icon(Icons.send_rounded, size: 18),
        label: const Text('Send link as text'),
      ),
    ]);
  }
}
