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

/// Share one or more profiles the way provider-style tunnel apps do.
///
/// Locking is automatic: when "Lock config" is on, the server address and credentials are
/// hidden and editing/exporting is blocked on the receiving phone. No PIN, no phone
/// passcode and no password is involved. A password is a separate, optional extra
/// (Advanced) that encrypts the file for one specific person.
class SharePage extends StatefulWidget {
  const SharePage({super.key, this.initial, this.selectAll = false});
  final ServerConfig? initial;
  final bool selectAll;
  @override
  State<SharePage> createState() => _SharePageState();
}

enum _Expiry { never, date, days }

class _Preset {
  const _Preset(this.label, this.icon, this.hint);
  final String label, hint;
  final IconData icon;
}

class _SharePageState extends State<SharePage> {
  static const _presets = [
    _Preset('Open', Icons.lock_open_rounded, 'No lock, no limits'),
    _Preset('Locked', Icons.lock_rounded, 'Hidden credentials, no re-share'),
    _Preset('Trial', Icons.hourglass_bottom_rounded, '1 day, 500 MB, 1 h sessions'),
    _Preset('Monthly', Icons.calendar_month_rounded, '30 days, 20 GB'),
  ];

  final title = TextEditingController();
  final note = TextEditingController();
  final author = TextEditingController();
  final password = TextEditingController();
  final device = TextEditingController();
  late final Set<String> chosen = {if (widget.initial != null) widget.initial!.id};

  int preset = 1; // index into _presets, -1 = custom
  _Expiry expiry = _Expiry.never;
  DateTime? date;
  int days = 30;
  bool lock = true;
  bool reshare = false;
  bool secure = true;
  bool rooted = false;
  int? sessionMin;
  int? dataMb;
  bool busy = false;
  bool showPw = false;

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

  void _applyPreset(int i) {
    setState(() {
      preset = i;
      switch (i) {
        case 0:
          lock = false; reshare = true; secure = false; rooted = false;
          expiry = _Expiry.never; sessionMin = null; dataMb = null;
        case 1:
          lock = true; reshare = false; secure = true; rooted = false;
          expiry = _Expiry.never; sessionMin = null; dataMb = null;
        case 2:
          lock = true; reshare = false; secure = true; rooted = true;
          expiry = _Expiry.days; days = 1; sessionMin = 60; dataMb = 500;
        case 3:
          lock = true; reshare = false; secure = true; rooted = false;
          expiry = _Expiry.days; days = 30; sessionMin = null; dataMb = 20480;
      }
    });
  }

  void _custom(VoidCallback f) => setState(() {
        preset = -1;
        f();
      });

  List<ServerConfig> get _selected => context.read<AppState>().configs.where((c) => chosen.contains(c.id)).toList();

  /// Limits of configs the sender received themselves can only be kept or tightened.
  ({bool lock, bool secure, bool rooted, DateTime? exp, int? mb, int? sess, bool inherited}) _effective() {
    final list = _selected;
    var l = lock, sec = secure, r = rooted, inherited = false;
    DateTime? exp = expiry == _Expiry.date && date != null
        ? DateTime(date!.year, date!.month, date!.day, 23, 59, 59).toUtc()
        : (expiry == _Expiry.days ? DateTime.now().toUtc().add(Duration(days: days)) : null);
    int? mb = dataMb, sess = sessionMin;
    for (final c in list) {
      if (c.locked) { l = true; inherited = true; }
      if (c.secure) sec = true;
      if (c.blockRooted) r = true;
      final own = c.effectiveExpiry;
      if (own != null && (exp == null || own.isBefore(exp))) { exp = own; inherited = true; }
      final left = c.dataLeftBytes;
      if (left != null) {
        final m = (left / (1024 * 1024)).floor();
        if (mb == null || m < mb) { mb = m; inherited = true; }
      }
      if (c.maxSessionMin != null && (sess == null || c.maxSessionMin! < sess)) { sess = c.maxSessionMin; inherited = true; }
    }
    return (lock: l, secure: sec, rooted: r, exp: exp, mb: mb, sess: sess, inherited: inherited);
  }

  Future<void> _create() async {
    final s = context.read<AppState>();
    final list = _selected;
    if (list.isEmpty) return toast(context, 'Pick at least one server to share.');
    if (list.any((c) => !c.allowShare)) return toast(context, 'One of these configs may not be re-shared.');
    if (expiry == _Expiry.date && date == null) return toast(context, 'Choose an expiry date.');
    final e = _effective();
    setState(() => busy = true);
    try {
      // Re-shares of "days after import" configs keep a relative countdown where possible.
      final relative = expiry == _Expiry.days && e.exp != null && list.every((c) => c.effectiveExpiry == null);
      final meta = ShareMeta(
        title: title.text.trim(),
        note: note.text.trim(),
        author: author.text.trim(),
        expiresAt: relative ? null : e.exp,
        validDays: relative ? days : null,
        locked: e.lock,
        allowReshare: e.lock ? reshare : true,
        deviceHash: device.text.trim().isEmpty ? null : await ConfigPackage.hashDeviceId(device.text),
        maxSessionMin: e.sess,
        dataLimitMb: e.mb,
        blockRooted: e.rooted,
        secure: e.lock && e.secure,
      );
      final env = await ConfigPackage.encode(meta, list, password: password.text);
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _ResultSheet(
          envelope: env,
          name: meta.title.isEmpty ? (list.length == 1 ? list.first.name : 'xray-configs') : meta.title,
          hasPassword: password.text.isNotEmpty,
          summary: _summaryChips(meta),
        ),
      );
    } catch (err) {
      if (mounted) toast(context, 'Could not create the share file: $err');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    s.log('info', 'Created a share package for ${list.length} server(s)');
  }

  List<String> _summaryChips(ShareMeta m) => [
        if (m.locked) 'Locked',
        if (m.expiresAt != null) 'Expires ${m.expiresAt!.toLocal().toString().substring(0, 10)}',
        if (m.validDays != null) '${m.validDays} day${m.validDays == 1 ? '' : 's'} after import',
        if (m.dataLimitMb != null) _fmtMb(m.dataLimitMb!),
        if (m.maxSessionMin != null) '${m.maxSessionMin} min sessions',
        if (m.deviceHash != null) 'One device',
        if (m.blockRooted) 'No root',
        if (password.text.isNotEmpty) 'Password',
      ];

  static String _fmtMb(int mb) => mb >= 1024 ? '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB' : '$mb MB';

  // ───────── building blocks ─────────

  Widget _field(TextEditingController c, String label, {int lines = 1, int? max, bool obscure = false, String? hint, Widget? suffix, ValueChanged<String>? onChanged}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          minLines: lines,
          maxLines: lines,
          maxLength: max,
          obscureText: obscure,
          autocorrect: false,
          onChanged: onChanged ?? (_) => setState(() {}),
          decoration: InputDecoration(labelText: label, hintText: hint, suffixIcon: suffix, filled: true, counterText: '', border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
        ),
      );

  Widget _card(String title, IconData icon, List<Widget> children, {String? sub}) {
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
          if (sub != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(sub, style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.35))),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }

  Widget _chips<T>(List<(T, String)> items, T? cur, ValueChanged<T> on) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (v, l) in items) ChoiceChip(label: Text(l), selected: cur == v, onSelected: (_) => _custom(() => on(v))),
      ]);

  Widget _toggle(String t, String sub, bool v, ValueChanged<bool> on, {bool enabled = true}) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12.5)),
        value: v,
        onChanged: enabled ? (x) => _custom(() => on(x)) : null,
      );

  /// What the receiving phone will show: a live preview, so senders know what they are handing out.
  Widget _preview() {
    final p = context.pal;
    final e = _effective();
    final list = _selected;
    final name = title.text.trim().isNotEmpty ? title.text.trim() : (list.length == 1 ? list.first.name : (list.isEmpty ? 'Server name' : '${list.length} servers'));
    final chips = <Widget>[
      if (e.lock) const Pill('Locked', icon: Icons.lock_rounded),
      if (e.exp != null) Pill(expiry == _Expiry.days && !e.inherited ? '$days day${days == 1 ? '' : 's'}' : 'Until ${e.exp!.toLocal().toString().substring(0, 10)}', color: p.warn, icon: Icons.timer_outlined),
      if (e.mb != null) Pill(_fmtMb(e.mb!), color: p.steel, icon: Icons.data_usage_rounded),
      if (e.sess != null) Pill('${e.sess} min sessions', color: p.steel, icon: Icons.schedule_rounded),
    ];
    return Glass(
      tint: p.accentSoft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.visibility_outlined, size: 16, color: p.dim),
          const SizedBox(width: 6),
          Text('What the receiver sees', style: TextStyle(color: p.dim, fontSize: 12.5, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(14)),
            child: Icon(e.lock ? Icons.lock_rounded : Icons.public_rounded, color: p.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              Text(e.lock ? 'Server address and credentials hidden' : 'Server details visible and editable', style: TextStyle(color: p.dim, fontSize: 12.5)),
            ]),
          ),
        ]),
        if (chips.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
        if (note.text.trim().isNotEmpty || author.text.trim().isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            width: double.infinity,
            decoration: BoxDecoration(color: alpha(p.accent, .08), borderRadius: BorderRadius.circular(14), border: Border.all(color: alpha(p.accent, .25))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (author.text.trim().isNotEmpty) Text('Message from ${author.text.trim()}', style: TextStyle(color: p.accent, fontSize: 12, fontWeight: FontWeight.w800)),
              if (note.text.trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(note.text.trim(), style: const TextStyle(height: 1.35))),
            ]),
          ),
        if (e.inherited)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('Some limits come from the config you received and cannot be loosened.', style: TextStyle(color: p.warn, fontSize: 12)),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    final e = _effective();
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
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 30), children: [
                SizedBox(
                  height: 78,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _presets.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => SizedBox(
                      width: 132,
                      child: Glass(
                        padding: const EdgeInsets.all(12),
                        tint: preset == i ? p.accentSoft : null,
                        onTap: () => _applyPreset(i),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                          Row(children: [
                            Icon(_presets[i].icon, size: 16, color: preset == i ? p.accent : p.dim),
                            const SizedBox(width: 6),
                            Text(_presets[i].label, style: TextStyle(fontWeight: FontWeight.w800, color: preset == i ? p.accent : p.text)),
                          ]),
                          const SizedBox(height: 3),
                          Text(_presets[i].hint, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.dim, fontSize: 11)),
                        ]),
                      ),
                    ),
                  ),
                ),
                _card('Servers', Icons.dns_rounded, [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final c in s.configs)
                      FilterChip(
                        label: Text(c.locked ? '${c.name} (locked)' : c.name, overflow: TextOverflow.ellipsis),
                        selected: chosen.contains(c.id),
                        onSelected: c.allowShare ? (v) => setState(() => v ? chosen.add(c.id) : chosen.remove(c.id)) : null,
                        avatar: c.allowShare ? null : const Icon(Icons.block_rounded, size: 15),
                      ),
                  ]),
                  if (s.configs.any((c) => !c.allowShare))
                    Padding(padding: const EdgeInsets.only(top: 8), child: Text('Crossed-out servers were shared with you without permission to pass them on.', style: TextStyle(color: p.dim, fontSize: 12))),
                ]),
                _card('Message', Icons.chat_bubble_outline_rounded, [
                  _field(title, 'Title (replaces the server name)', max: 60),
                  _field(note, 'Message shown when they import it', lines: 3, max: 400, hint: 'Welcome! Plan: Monthly. Support: t.me/yourname'),
                  _field(author, 'From (your name, brand or contact)', max: 40),
                ]),
                _card('Validity', Icons.timer_outlined, [
                  SegmentedButton<_Expiry>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(selectedBackgroundColor: p.accentSoft, selectedForegroundColor: p.accent),
                    segments: const [
                      ButtonSegment(value: _Expiry.never, label: Text('No expiry')),
                      ButtonSegment(value: _Expiry.date, label: Text('Fixed date')),
                      ButtonSegment(value: _Expiry.days, label: Text('Days')),
                    ],
                    selected: {expiry},
                    onSelectionChanged: (v) => _custom(() => expiry = v.first),
                  ),
                  if (expiry == _Expiry.date)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.event_rounded),
                        label: Text(date == null ? 'Choose date' : date!.toString().substring(0, 10)),
                        onPressed: () async {
                          final d = await showDatePicker(context: context, initialDate: date ?? DateTime.now().add(const Duration(days: 30)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
                          if (d != null) _custom(() => date = d);
                        },
                      ),
                    ),
                  if (expiry == _Expiry.days) ...[
                    const SizedBox(height: 12),
                    _chips<int>(const [(1, '1 day'), (3, '3 days'), (7, '7 days'), (30, '30 days'), (90, '90 days'), (365, '1 year')], days, (v) => days = v),
                    const SizedBox(height: 6),
                    Text('The countdown starts when the receiver imports the config.', style: TextStyle(color: p.dim, fontSize: 12.5)),
                  ],
                ]),
                _card('Protection', Icons.shield_outlined, [
                  _toggle('Lock config', 'Locks automatically: the server address and credentials are hidden and editing, copying and exporting are blocked. No PIN or password needed.', lock, (v) => lock = v),
                  if (lock) ...[
                    _toggle('Block re-sharing', 'The receiver cannot pass the config on', !reshare, (v) => reshare = !v),
                    _toggle('Hide from screenshots', 'Blocks screenshots and the recent-apps preview while it is selected', secure, (v) => secure = v),
                  ],
                  _toggle('Block rooted phones', 'Refuses to run when root is detected', rooted, (v) => rooted = v),
                  const SizedBox(height: 4),
                  _field(device, 'Lock to one device (optional)', hint: 'Receiver\'s Device ID, e.g. XR-ABCD-EF23-GH45'),
                ]),
                _card('Limits', Icons.speed_rounded, sub: 'Enforced by the app on the receiving phone.', [
                  Text('Session length', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  _chips<int?>(const [(null, 'No limit'), (30, '30 min'), (60, '1 h'), (180, '3 h'), (720, '12 h')], sessionMin, (v) => sessionMin = v),
                  const SizedBox(height: 14),
                  Text('Total data', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  _chips<int?>(const [(null, 'No limit'), (500, '500 MB'), (1024, '1 GB'), (5120, '5 GB'), (20480, '20 GB'), (102400, '100 GB')], dataMb, (v) => dataMb = v),
                ]),
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Glass(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                        leading: Icon(Icons.key_rounded, color: p.accent, size: 20),
                        title: Text('Advanced: extra encryption', style: TextStyle(color: p.accent, fontWeight: FontWeight.w800, fontSize: 13.5)),
                        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                        children: [
                          Text('Optional. Encrypts the file with a password you choose, so only someone who knows it can import it. This is separate from locking and has nothing to do with any phone PIN.', style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.4)),
                          const SizedBox(height: 10),
                          _field(
                            password,
                            'Password',
                            obscure: !showPw,
                            suffix: IconButton(icon: Icon(showPw ? Icons.visibility_off_rounded : Icons.visibility_rounded), onPressed: () => setState(() => showPw = !showPw)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _preview(),
                const SizedBox(height: 10),
                Text(
                  'Honest note: the app has to give the credentials to the VPN core to connect, so a lock stops casual viewing, copying and editing but cannot stop someone who controls a rooted phone. Expiry follows the receiver\'s clock. Only share with people you trust.',
                  style: TextStyle(color: p.dim, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: busy ? null : _create,
                  icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.ios_share_rounded),
                  label: Text(busy ? 'Encrypting…' : (e.lock ? 'Create locked config' : 'Create share file'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
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
  const _ResultSheet({required this.envelope, required this.name, required this.hasPassword, this.summary = const []});
  final String envelope, name;
  final bool hasPassword;
  final List<String> summary;

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
      if (summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Wrap(spacing: 6, runSpacing: 6, children: [for (final x in summary) Pill(x)])),
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
