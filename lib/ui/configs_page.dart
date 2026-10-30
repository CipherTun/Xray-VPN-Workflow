import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/link_parser.dart';
import '../core/models.dart';
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
                  body: 'Paste a vless://, vmess://, trojan://, ss:// or ssh:// link, import a subscription, or add an SSH server by hand.',
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
            child: Text(c.proto.label.substring(0, c.proto == Proto.shadowsocks ? 2 : 1).toUpperCase(), style: TextStyle(fontWeight: FontWeight.w800, color: isSel ? p.accent : p.dim, fontSize: 16)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5))),
                if (c.locked) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.lock_rounded, size: 14, color: p.dim)),
                if (c.favorite) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.star_rounded, size: 16, color: p.warn)),
              ]),
              const SizedBox(height: 3),
              Text('${c.proto.label}${c.p('net') == '' || c.p('net') == 'tcp' ? '' : ' · ${c.p('net')}'}${c.p('security', 'none') == 'none' ? '' : ' · ${c.p('security')}'}  ·  ${c.locked ? (c.author.isEmpty ? 'Locked' : 'From ${c.author}') : c.host}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.dim, fontSize: 12)),
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
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        if (!c.locked) ListTile(leading: const Icon(Icons.edit_rounded), title: const Text('Edit'), onTap: () { Navigator.pop(ctx); showConfigEditor(context, c); }),
        if (c.allowShare) ListTile(leading: const Icon(Icons.ios_share_rounded), title: const Text('Share…'), subtitle: const Text('Note, expiry, lock, password'), onTap: () { Navigator.pop(ctx); Navigator.of(context).push(MaterialPageRoute(builder: (_) => SharePage(initial: c))); }),
        ListTile(leading: Icon(c.favorite ? Icons.star_border_rounded : Icons.star_rounded), title: Text(c.favorite ? 'Remove favorite' : 'Mark as favorite'), onTap: () { Navigator.pop(ctx); s.toggleFavorite(c); }),
        ListTile(leading: const Icon(Icons.speed_rounded), title: const Text('Test latency'), onTap: () { Navigator.pop(ctx); s.pingOne(c); }),
        if (!c.locked) ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: const Text('Copy plain link'),
          onTap: () {
            Navigator.pop(ctx);
            final l = LinkParser.toLink(c);
            if (l == null) {
              toast(context, 'Profiles with a private key cannot be shared as a link.');
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
                subtitle: Text('${c.proto.label} · ${c.host}'),
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
          subtitle: const Text('Tunnel through any SSH host (DartSSH2)'),
          onTap: () {
            Navigator.pop(ctx);
            showConfigEditor(context, null, startProto: Proto.ssh);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_note_rounded),
          title: const Text('Add manually'),
          subtitle: const Text('VLESS, VMess, Trojan, Shadowsocks'),
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

  static const keys = ['name', 'host', 'port', 'id', 'user', 'privateKey', 'passphrase', 'method', 'aid', 'sni', 'fp', 'path', 'hostHdr', 'flow', 'pbk', 'sid', 'serviceName'];

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
            'port' => '${e?.port ?? (proto == Proto.ssh ? 22 : 443)}',
            'hostHdr' => e?.p('host') ?? '',
            _ => e?.p(k) ?? '',
          },
        ),
    };
  }

  @override
  void dispose() {
    for (final c in t.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _f(String k, String label, {bool obscure = false, int lines = 1, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: t[k],
          obscureText: obscure,
          minLines: lines,
          maxLines: lines,
          keyboardType: type,
          autocorrect: false,
          decoration: InputDecoration(labelText: label, filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
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

  void _save() {
    final host = t['host']!.text.trim();
    final port = int.tryParse(t['port']!.text.trim());
    if (host.isEmpty || port == null) {
      toast(context, 'Enter a host and a valid port.');
      return;
    }
    final params = <String, String>{};
    void put(String k, [String? src]) {
      final v = t[src ?? k]!.text.trim();
      if (v.isNotEmpty) params[k] = v;
    }

    put('id');
    if (proto == Proto.ssh) {
      put('user');
      put('privateKey');
      put('passphrase');
      // keep multi-line keys intact
      if (t['privateKey']!.text.trim().isNotEmpty) params['privateKey'] = t['privateKey']!.text;
    } else {
      params['net'] = net;
      params['security'] = sec;
      for (final k in ['sni', 'fp', 'path', 'flow', 'pbk', 'sid', 'serviceName', 'method', 'aid']) {
        put(k);
      }
      put('host', 'hostHdr');
    }
    final c = ServerConfig(
      id: widget.existing?.id ?? ServerConfig.newId(),
      name: t['name']!.text.trim().isEmpty ? host : t['name']!.text.trim(),
      proto: proto,
      host: host,
      port: port,
      params: params,
      favorite: widget.existing?.favorite ?? false,
      group: widget.existing?.group ?? '',
    );
    context.read<AppState>().upsert(c);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final ssh = proto == Proto.ssh;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 18, 20, 24), shrinkWrap: true, children: [
        Text(widget.existing == null ? 'New server' : 'Edit server', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        _chips('Protocol', [for (final x in Proto.values) x.label], proto.label, (v) => proto = Proto.values.firstWhere((e) => e.label == v)),
        _f('name', 'Name'),
        _f('host', 'Host'),
        _f('port', 'Port', type: TextInputType.number),
        if (ssh) ...[
          _f('user', 'Username'),
          _f('id', 'Password', obscure: true),
          _f('privateKey', 'Private key (PEM, optional)', lines: 4),
          _f('passphrase', 'Key passphrase', obscure: true),
          Text('The first connection trusts the server host key and remembers it. A changed key is refused.', style: TextStyle(color: p.dim, fontSize: 12.5)),
        ] else ...[
          _f('id', proto == Proto.vless || proto == Proto.vmess ? 'UUID' : 'Password'),
          if (proto == Proto.shadowsocks) _f('method', 'Cipher (e.g. aes-256-gcm)'),
          if (proto == Proto.vmess) _f('aid', 'Alter ID'),
          if (proto != Proto.shadowsocks) ...[
            _chips('Transport', const ['tcp', 'ws', 'grpc', 'xhttp', 'httpupgrade'], net, (v) => net = v),
            _chips('Security', const ['none', 'tls', 'reality'], sec, (v) => sec = v),
            if (sec != 'none') _f('sni', 'SNI'),
            if (sec != 'none') _f('fp', 'Fingerprint (chrome, firefox…)'),
            if (sec == 'reality') ...[_f('pbk', 'Reality public key'), _f('sid', 'Reality short ID')],
            if (net == 'ws' || net == 'xhttp' || net == 'httpupgrade') ...[_f('path', 'Path'), _f('hostHdr', 'Host header')],
            if (net == 'grpc') _f('serviceName', 'gRPC service name'),
            if (proto == Proto.vless) _f('flow', 'Flow (xtls-rprx-vision)'),
          ],
        ],
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
