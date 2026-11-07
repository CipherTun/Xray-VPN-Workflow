import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/link_parser.dart';
import '../core/models.dart';
import '../core/v2tun_config.dart';
import '../state/app_state.dart';
import 'import_page.dart';
import 'share_page.dart';
import 'theme.dart';
import 'widgets.dart';

class ConfigsPage extends StatelessWidget {
  const ConfigsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = context.pal;
    return Column(children: [
      PageHeader(
        'Configs',
        subtitle: '${s.configs.length} server${s.configs.length == 1 ? '' : 's'}',
        actions: [
          RoundIconButton(icon: Icons.speed_rounded, tooltip: 'Test latency', onTap: () async {
            toast(context, 'Testing latency…');
            await s.pingAll();
          }),
          RoundIconButton(icon: Icons.add_rounded, tooltip: 'Add', onTap: () => showAddSheet(context)),
        ],
      ),
      Expanded(
        child: s.configs.isEmpty
            ? Center(
                child: EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'No servers yet',
                  body: 'Paste a vless://, vmess://, trojan://, ss://, ssh://, socks5://, hysteria2:// or hy2:// link, import a subscription, or add a server by hand.',
                  action: FilledButton.icon(
                    onPressed: () => showAddSheet(context),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add server'),
                    style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
                itemCount: s.configs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _ConfigTile(s.configs[i]),
              ),
      ),
    ]);
  }
}

class _ConfigTile extends StatelessWidget {
  const _ConfigTile(this.c);
  final ServerConfig c;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final p = context.pal;
    final isSel = context.select<AppState, bool>((s) => s.selectedId == c.id);
    final inFailover = context.select<AppState, bool>((s) => s.settings.get<String>('failoverMode') == 'ordered' && s.settings.list('failoverIds').contains(c.id));
    return Dismissible(
      key: ValueKey(c.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: alpha(p.bad, .25), borderRadius: BorderRadius.circular(24)),
        child: Icon(Icons.delete_rounded, color: p.bad),
      ),
      onDismissed: (_) => s.remove(c.id),
      child: Glass(
        tint: isSel ? p.accentSoft : null,
        onTap: () => s.select(c.id),
        onLongPress: () => showConfigMenu(context, c),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: alpha(isSel ? p.accent : p.dim, .16), borderRadius: BorderRadius.circular(14)),
            child: Text(c.proto.badge, style: TextStyle(fontWeight: FontWeight.w800, color: isSel ? p.accent : p.dim, fontSize: c.proto.badge.length > 2 ? 12.5 : 16)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
                if (c.locked) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.lock_rounded, size: 14, color: p.dim)),
                if (c.favorite) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.star_rounded, size: 16, color: p.warn)),
                if (inFailover) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.swap_horiz_rounded, size: 16, color: p.steel)),
              ]),
              const SizedBox(height: 3),
              Text('${c.proto.label}${c.p('net') == '' || c.p('net') == 'tcp' ? '' : ' · ${c.p('net')}'}${c.p('security', 'none') == 'none' ? '' : ' · ${c.p('security')}'}${c.proto == Proto.ssh && c.p('hostKey').isNotEmpty ? ' · pinned' : ''}  ·  ${c.locked ? (c.author.isEmpty ? 'Locked' : 'From ${c.author}') : c.host}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.dim, fontSize: 12)),
            ]),
          ),
          if (c.note.isNotEmpty)
            GestureDetector(
              onTap: () => showDialog(context: context, builder: (ctx) => AlertDialog(title: Text(c.author.isEmpty ? 'Message' : 'Message from ${c.author}'), content: Text(c.note), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))])),
              child: Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.sticky_note_2_outlined, size: 20, color: p.accent)),
            ),
          if (expiryText(c) != null) Padding(padding: const EdgeInsets.only(right: 6), child: Pill(expiryText(c)!, color: c.expired ? p.bad : p.warn)),
          if (c.pingMs != null) Pill(c.pingMs! < 0 ? 'Timeout' : '${c.pingMs} ms', color: pingColor(p, c.pingMs)),
          if (isSel) Padding(padding: const EdgeInsets.only(left: 8), child: Icon(Icons.check_circle_rounded, color: p.accent, size: 22)),
        ]),
      ),
    );
  }
}

void showConfigMenu(BuildContext context, ServerConfig c) {
  final s = context.read<AppState>();
  final failoverOn = s.settings.get<String>('failoverMode') == 'ordered';
  final inFailover = s.settings.list('failoverIds').contains(c.id);
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        if (!c.locked) ListTile(leading: const Icon(Icons.edit_rounded), title: const Text('Edit'), onTap: () { Navigator.pop(ctx); showConfigEditor(context, c); }),
        if (c.allowShare) ListTile(leading: const Icon(Icons.ios_share_rounded), title: const Text('Share…'), subtitle: const Text('Note, expiry, lock, password'), onTap: () { Navigator.pop(ctx); Navigator.of(context).push(MaterialPageRoute(builder: (_) => SharePage(initial: c))); }),
        ListTile(leading: Icon(c.favorite ? Icons.star_border_rounded : Icons.star_rounded), title: Text(c.favorite ? 'Remove favorite' : 'Mark as favorite'), onTap: () { Navigator.pop(ctx); s.toggleFavorite(c); }),
        ListTile(leading: const Icon(Icons.speed_rounded), title: const Text('Test latency'), onTap: () { Navigator.pop(ctx); s.pingOne(c); }),
        if (failoverOn && !c.expired)
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded),
            title: Text(inFailover ? 'Remove from failover list' : 'Use as failover server'),
            subtitle: const Text('Tried in order when the selected server cannot connect'),
            onTap: () {
              Navigator.pop(ctx);
              final ids = s.settings.list('failoverIds');
              s.setSetting('failoverIds', inFailover ? ids.where((x) => x != c.id).toList() : [...ids, c.id]);
            },
          ),
        if (!c.locked && c.proto == Proto.ssh && c.p('hostKey').isNotEmpty)
          ListTile(
            leading: const Icon(Icons.key_off_rounded),
            title: const Text('Forget pinned host key'),
            subtitle: const Text('The next connection pins the key the server shows then'),
            onTap: () {
              Navigator.pop(ctx);
              c.params.remove('hostKey');
              s.upsert(c);
              toast(context, 'Host key forgotten');
            },
          ),
        if (!c.locked) ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: const Text('Copy plain link'),
          onTap: () {
            Navigator.pop(ctx);
            final l = LinkParser.toLink(c);
            if (l == null) {
              toast(context, 'This profile cannot be shared as a link (private key, payload, TLS SSH or HTTP proxy).');
            } else {
              Clipboard.setData(ClipboardData(text: l));
              toast(context, 'Link copied');
            }
          },
        ),
        ListTile(leading: Icon(Icons.delete_rounded, color: ctx.pal.bad), title: Text('Delete', style: TextStyle(color: ctx.pal.bad)), onTap: () { Navigator.pop(ctx); s.remove(c.id); }),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

void showServerPicker(BuildContext context) {
  final s = context.read<AppState>();
  if (s.configs.isEmpty) {
    showAddSheet(context);
    return;
  }
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .6,
      maxChildSize: .92,
      builder: (_, ctl) => Consumer<AppState>(
        builder: (_, st, __) {
          final list = [...st.configs]..sort((a, b) {
              if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
              final pa = (a.pingMs ?? 99999) < 0 ? 99999 : (a.pingMs ?? 99999);
              final pb = (b.pingMs ?? 99999) < 0 ? 99999 : (b.pingMs ?? 99999);
              return pa.compareTo(pb);
            });
          return ListView(controller: ctl, padding: const EdgeInsets.fromLTRB(12, 14, 12, 24), children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8), child: Text('Choose a server', style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
            for (final c in list)
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                selected: c.id == st.selectedId,
                title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${c.proto.label} · ${c.safeHost}'),
                trailing: c.pingMs == null ? null : Pill(c.pingMs! < 0 ? 'Timeout' : '${c.pingMs} ms', color: pingColor(ctx.pal, c.pingMs)),
                onTap: () {
                  st.select(c.id);
                  Navigator.pop(ctx);
                },
              ),
          ]);
        },
      ),
    ),
  );
}

void showAddSheet(BuildContext context) {
  final s = context.read<AppState>();
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.file_download_rounded),
          title: const Text('Import config'),
          subtitle: const Text('Shared file, xrayvpn:// link, text or QR link'),
          onTap: () {
            Navigator.pop(ctx);
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportPage()));
          },
        ),
        ListTile(
          leading: const Icon(Icons.content_paste_rounded),
          title: const Text('Paste from clipboard'),
          subtitle: const Text('Share links or a subscription list'),
          onTap: () async {
            Navigator.pop(ctx);
            final d = await Clipboard.getData('text/plain');
            final n = (d?.text == null) ? 0 : s.importText(d!.text!);
            if (context.mounted) toast(context, n == 0 ? 'No valid links found in the clipboard.' : 'Added $n server${n == 1 ? '' : 's'}');
          },
        ),
        ListTile(
          leading: const Icon(Icons.cloud_download_rounded),
          title: const Text('Import subscription URL'),
          onTap: () {
            Navigator.pop(ctx);
            _subscriptionDialog(context);
          },
        ),
        if (s.subs.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.sync_rounded),
            title: Text('Update subscriptions (${s.subs.length})'),
            onTap: () async {
              Navigator.pop(ctx);
              toast(context, 'Updating…');
              final n = await s.refreshSubscriptions(force: true);
              if (context.mounted) toast(context, 'Updated: $n servers');
            },
          ),
        if (s.configs.any((c) => c.allowShare))
          ListTile(
            leading: const Icon(Icons.backup_rounded),
            title: const Text('Back up / share all'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SharePage(selectAll: true)));
            },
          ),
        ListTile(
          leading: const Icon(Icons.terminal_rounded),
          title: const Text('Add SSH server'),
          subtitle: const Text('Direct, over TLS, over WebSocket or with an HTTP payload'),
          onTap: () {
            Navigator.pop(ctx);
            showConfigEditor(context, null, startProto: Proto.ssh);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_note_rounded),
          title: const Text('Add manually'),
          subtitle: const Text('VLESS, VMess, Trojan, Shadowsocks, SOCKS, HTTP, Hysteria'),
          onTap: () {
            Navigator.pop(ctx);
            showConfigEditor(context, null);
          },
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

Future<void> _subscriptionDialog(BuildContext context) async {
  final s = context.read<AppState>();
  final ctl = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Subscription URL'),
      content: TextField(controller: ctl, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'https://…')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Import')),
      ],
    ),
  );
  if (url == null || url.isEmpty) return;
  try {
    final n = await s.importSubscription(url);
    if (context.mounted) toast(context, n == 0 ? 'The subscription had no supported links.' : 'Added $n server${n == 1 ? '' : 's'}');
  } catch (e) {
    if (context.mounted) toast(context, 'Import failed: $e');
  }
}

// ───────── editor ─────────

void showConfigEditor(BuildContext context, ServerConfig? existing, {Proto startProto = Proto.vless}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(value: context.read<AppState>(), child: _Editor(existing: existing, startProto: startProto)),
  );
}

class _Editor extends StatefulWidget {
  const _Editor({this.existing, required this.startProto});
  final ServerConfig? existing;
  final Proto startProto;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late Proto proto = widget.existing?.proto ?? widget.startProto;
  late final Map<String, TextEditingController> t;
  late String net = widget.existing?.p('net', 'tcp') ?? 'tcp';
  late String sec = widget.existing?.p('security', 'none') ?? 'none';
  late String stage = widget.existing?.p('payloadStage', 'pre-tls') ?? 'pre-tls';
  late bool insecure = widget.existing?.p('allowInsecure') == '1';

  List<String> presets = const [];
  String? payloadError;
  bool probing = false;
  Timer? _debounce;

  static const keys = [
    'name', 'host', 'port', 'id', 'user', 'privateKey', 'passphrase', 'hostKey', 'method', 'aid', 'sni', 'fp', 'alpn', 'path', 'hostHdr',
    'flow', 'pbk', 'sid', 'serviceName', 'obfs', 'pin', 'upMbps', 'downMbps', 'payload', 'payloadHost', 'proxy', 'responseMap',
  ];

  /// Protocols that carry a network / security / payload choice (the library applies them to the non-Hysteria family).
  bool get _hasTransport => proto == Proto.vless || proto == Proto.vmess || proto == Proto.trojan || proto == Proto.ssh;
  bool get _userPass => proto == Proto.ssh || proto == Proto.socks5 || proto == Proto.http || proto == Proto.https;
  int get _defaultPort => switch (proto) {
        Proto.ssh => 22,
        Proto.socks5 || Proto.socks4 => 1080,
        Proto.http => 8080,
        _ => 443,
      };

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    t = {
      for (final k in keys)
        k: TextEditingController(
          text: switch (k) {
            'name' => e?.name ?? '',
            'host' => e?.host ?? '',
            'port' => '${e?.port ?? _defaultPort}',
            'hostHdr' => e?.p('host') ?? '',
            _ => e?.p(k) ?? '',
          },
        ),
    };
    final bridge = context.read<AppState>().bridge;
    bridge.payloadPresets().then((v) {
      if (mounted) setState(() => presets = v.isEmpty ? const ['@connect', '@ssh-ws'] : v);
    });
    if (t['payload']!.text.isNotEmpty) _onPayloadChanged(t['payload']!.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in t.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _f(String k, String label, {bool obscure = false, int lines = 1, TextInputType? type, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: t[k],
          obscureText: obscure,
          minLines: lines,
          maxLines: lines,
          keyboardType: type,
          autocorrect: false,
          decoration: InputDecoration(labelText: label, hintText: hint, filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
        ),
      );

  Widget _chips(String label, List<String> opts, String cur, ValueChanged<String> on) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 12.5)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [for (final o in opts) ChoiceChip(label: Text(o), selected: cur == o, onSelected: (_) => setState(() => on(o)))]),
      ]),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, style: TextStyle(color: context.pal.dim, fontSize: 12, height: 1.4)),
      );

  Widget _insecureSwitch() => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: insecure,
        onChanged: (v) => setState(() => insecure = v),
        title: const Text('Allow insecure certificate'),
        subtitle: const Text('Skips certificate checks. Only for servers you control.'),
      );

  // ── library helpers: host key probe, payload validation and preview ──

  void _onPayloadChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() => payloadError = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      // The same text the config builder sends to the library.
      final err = await context.read<AppState>().bridge.validatePayload(migratePayload(v).template);
      if (mounted) setState(() => payloadError = err);
    });
  }

  Future<void> _previewPayload() async {
    final st = context.read<AppState>();
    final tpl = migratePayload(t['payload']!.text).template;
    final ph = t['payloadHost']!.text.trim();
    final host = ph.isNotEmpty ? ph : (t['host']!.text.trim().isEmpty ? 'example.com' : t['host']!.text.trim());
    final port = int.tryParse(t['port']!.text.trim()) ?? 22;
    try {
      final out = await st.bridge.previewPayload(tpl, host, port);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Payload preview'),
          content: SingleChildScrollView(child: SelectableText(out, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4))),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> _fetchHostKey() async {
    final c = _build();
    if (c == null) return;
    final st = context.read<AppState>();
    setState(() => probing = true);
    try {
      final cfg = buildV2tunConfig(c, st.settings, forPing: true);
      final fp = await st.bridge.probeHostKey(jsonEncode(cfg), timeoutSec: st.settings.get<int>('connectTimeout'));
      if (!mounted) return;
      t['hostKey']!.text = fp;
      toast(context, 'Host key read. Check it against the server before saving.');
    } catch (e) {
      if (mounted) toast(context, 'Could not read the host key: $e');
    } finally {
      if (mounted) setState(() => probing = false);
    }
  }

  // ── form -> profile ──

  ServerConfig? _build() {
    final host = t['host']!.text.trim();
    final port = int.tryParse(t['port']!.text.trim());
    if (host.isEmpty || port == null) {
      toast(context, 'Enter a host and a valid port.');
      return null;
    }
    // Start from what the profile already has, so parameters this form does not show (mode, spx, ...) survive.
    final params = Map<String, String>.from(widget.existing?.params ?? const <String, String>{});
    void put(String k, [String? src]) {
      final v = t[src ?? k]!.text.trim();
      if (v.isEmpty) {
        params.remove(k);
      } else {
        params[k] = v;
      }
    }

    final hy = proto.isHysteria;
    if (proto != Proto.socks4) put('id');
    if (_userPass || proto == Proto.socks4) put('user');
    if (proto == Proto.ssh) {
      put('passphrase');
      put('hostKey');
      // Keep multi-line keys intact.
      final key = t['privateKey']!.text;
      if (key.trim().isEmpty) {
        params.remove('privateKey');
      } else {
        params['privateKey'] = key;
      }
    }
    if (proto == Proto.vmess) put('aid');
    if (proto == Proto.shadowsocks) put('method');

    var tls = hy || proto == Proto.https;
    if (_hasTransport) {
      params['net'] = net;
      params['security'] = sec;
      tls = sec == 'tls';
      if (sec != 'none') {
        put('sni');
        put('fp');
      }
      if (sec == 'tls') put('alpn');
      if (sec == 'reality') {
        put('pbk');
        put('sid');
      }
      if (net == 'ws' || net == 'xhttp' || net == 'httpupgrade' || net == 'h2') {
        put('path');
        put('host', 'hostHdr');
      }
      if (net == 'grpc') put('serviceName');
      if (proto == Proto.vless) put('flow');
      put('payload');
      put('payloadHost');
      put('proxy');
      put('responseMap');
      if (sec == 'tls' && t['payload']!.text.trim().isNotEmpty) {
        params['payloadStage'] = stage;
      } else {
        params.remove('payloadStage');
      }
    }
    if (hy) {
      put('sni');
      put('obfs');
      put('downMbps');
      if (proto == Proto.hysteria2) put('pin');
      if (proto == Proto.hysteria1) {
        put('alpn');
        put('upMbps');
      }
    }
    if (proto == Proto.https) put('sni');
    if (tls && insecure) {
      params['allowInsecure'] = '1';
    } else {
      params.remove('allowInsecure');
    }

    return ServerConfig(
      id: widget.existing?.id ?? ServerConfig.newId(),
      name: t['name']!.text.trim().isEmpty ? host : t['name']!.text.trim(),
      proto: proto,
      host: host,
      port: port,
      params: params,
      favorite: widget.existing?.favorite ?? false,
      group: widget.existing?.group ?? '',
    );
  }

  void _save() {
    if (payloadError != null) {
      toast(context, 'Fix the payload first: $payloadError');
      return;
    }
    final c = _build();
    if (c == null) return;
    context.read<AppState>().upsert(c);
    Navigator.pop(context);
  }

  Widget _payloadSection() {
    final p = context.pal;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 4),
      Text('HTTP payload (optional)', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 12.5)),
      const SizedBox(height: 8),
      if (presets.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (final n in presets) ActionChip(label: Text(n), onPressed: () {
              t['payload']!.text = n;
              _onPayloadChanged(n);
              setState(() {});
            }),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: t['payload'],
          minLines: 3,
          maxLines: 3,
          autocorrect: false,
          onChanged: _onPayloadChanged,
          decoration: InputDecoration(labelText: 'Payload or preset', errorText: payloadError, errorMaxLines: 3, filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
        ),
      ),
      if (t['payload']!.text.trim().isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.only(bottom: 12), child: OutlinedButton.icon(onPressed: payloadError == null ? _previewPayload : null, icon: const Icon(Icons.visibility_rounded, size: 18), label: const Text('Preview what is sent'))),
        ),
      _f('payloadHost', 'Payload host (blank = server host)'),
      _f('proxy', 'HTTP proxy to send it through (host:port, optional)'),
      _f('responseMap', 'Response override (e.g. 302=200, 3xx=200)'),
      if (sec == 'tls') _chips('Send payload', const ['pre-tls', 'post-tls'], stage, (v) => stage = v),
      _note('HTTP Injector style payloads, checked by the tunnel library. Placeholders: [host] [port] [host_port] [protocol] [method] [crlf] [cr] [lf] [split] [instant_split] [delay_split] [rotate=a|b] [random=a|b] [ua]. Presets such as @connect and @ssh-ws are expanded by the library. Old [sni=…] and [rotate=a;b] spellings are converted, and [tls] / [plain] are replaced by the Security setting. With an HTTP proxy the connection goes to the proxy and the payload names the real server.'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final ssh = proto == Proto.ssh;
    final hy = proto.isHysteria;
    final nets = ssh ? const ['tcp', 'ws'] : const ['tcp', 'ws', 'grpc', 'xhttp', 'httpupgrade', 'h2'];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 18, 20, 24), shrinkWrap: true, children: [
        Text(widget.existing == null ? 'New server' : 'Edit server', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        _chips('Protocol', [for (final x in Proto.values) x.label], proto.label, (v) {
          final old = _defaultPort;
          proto = Proto.values.firstWhere((e) => e.label == v);
          // Follow the usual port while it is still the default of the previous protocol.
          if (widget.existing == null && t['port']!.text.trim() == '$old') t['port']!.text = '$_defaultPort';
          if (ssh != (proto == Proto.ssh) && !nets.contains(net)) net = 'tcp';
        }),
        _f('name', 'Name'),
        _f('host', 'Host'),
        _f('port', 'Port', type: TextInputType.number),
        if (_userPass || proto == Proto.socks4) _f('user', proto == Proto.socks4 ? 'User ID (optional)' : 'Username'),
        if (ssh) ...[
          _f('id', 'Password', obscure: true),
          _f('privateKey', 'Private key (PEM, optional)', lines: 4),
          _f('passphrase', 'Key passphrase', obscure: true),
          _note('Encrypted keys are not supported by the tunnel library yet. Use an unencrypted key.'),
          _f('hostKey', 'Pinned host key', hint: 'SHA256:…'),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                onPressed: probing ? null : _fetchHostKey,
                icon: probing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fingerprint_rounded, size: 18),
                label: Text(probing ? 'Contacting the server…' : 'Fetch from server'),
              ),
            ),
          ),
          _note('The first connection pins the key the server shows (trust on first use), and the library refuses a different key afterwards. Fetch it here to check it before you connect, or clear the field to pin again.'),
        ] else if (proto == Proto.vless || proto == Proto.vmess)
          _f('id', 'UUID')
        else if (proto != Proto.socks4 && !_userPass)
          _f('id', hy ? 'Auth password' : 'Password'),
        if (_userPass && !ssh) _f('id', 'Password', obscure: true),
        if (proto == Proto.shadowsocks) _f('method', 'Cipher (e.g. aes-256-gcm)'),
        if (proto == Proto.vmess) _f('aid', 'Alter ID'),
        if (_hasTransport) ...[
          _chips('Transport', nets, net, (v) => net = v),
          _chips('Security', ssh ? const ['none', 'tls'] : const ['none', 'tls', 'reality'], sec, (v) => sec = v),
          if (sec != 'none') _f('sni', 'SNI (blank = server host)'),
          if (sec != 'none') _f('fp', 'Fingerprint (chrome, firefox, safari, ios, android, edge, random)'),
          if (sec == 'tls') _f('alpn', 'ALPN (comma separated, optional)'),
          if (sec == 'tls') _insecureSwitch(),
          if (sec == 'reality') ...[_f('pbk', 'Reality public key'), _f('sid', 'Reality short ID')],
          if (net == 'ws' || net == 'xhttp' || net == 'httpupgrade' || net == 'h2') ...[_f('path', 'Path'), _f('hostHdr', 'Host header')],
          if (net == 'grpc') _f('serviceName', 'gRPC service name'),
          if (proto == Proto.vless) _f('flow', 'Flow (xtls-rprx-vision)'),
          _payloadSection(),
        ],
        if (hy) ...[
          _f('sni', 'SNI (blank = server host)'),
          _insecureSwitch(),
          _f('obfs', 'Obfuscation password (optional)'),
          if (proto == Proto.hysteria2) _f('pin', 'Pinned certificate SHA-256 (optional)'),
          if (proto == Proto.hysteria1) _f('alpn', 'ALPN (optional)'),
          if (proto == Proto.hysteria1) _f('upMbps', 'Upload limit, Mbps (optional)', type: TextInputType.number),
          _f('downMbps', 'Download limit, Mbps (optional)', type: TextInputType.number),
        ],
        if (proto == Proto.https) ...[_f('sni', 'SNI (blank = server host)'), _insecureSwitch()],
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
          child: const Text('Save server', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
      ]),
    );
  }
}
