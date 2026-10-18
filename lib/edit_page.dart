import 'package:flutter/material.dart';

import 'models.dart';
import 'tools_page.dart';

class EditPage extends StatefulWidget {
  const EditPage({super.key, required this.profile, required this.all});
  final Profile profile;
  final List<Profile> all;
  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final TextEditingController _name = TextEditingController(text: widget.profile.name);
  late final TextEditingController _payload =
      TextEditingController(text: widget.profile.s('payload'));
  late final Map<String, dynamic> _d = Map<String, dynamic>.from(widget.profile.data);

  Profile get p => widget.profile;

  // ---- field helpers ----
  Widget tf(String k, String label,
      {int lines = 1,
      bool obscure = false,
      TextInputType? type,
      String def = '',
      String? hint,
      bool mono = false}) {
    if (def.isNotEmpty) _d.putIfAbsent(k, () => def);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: ValueKey('f_$k'),
        initialValue: _d[k]?.toString() ?? '',
        onChanged: (v) => _d[k] = v,
        obscureText: obscure,
        keyboardType: type,
        minLines: lines,
        maxLines: obscure ? 1 : lines,
        style: mono ? const TextStyle(fontFamily: 'monospace', fontSize: 12) : null,
        decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: label,
            hintText: hint,
            alignLabelWithHint: true),
      ),
    );
  }

  Widget dd(String k, String label, List<String> opts, String def) {
    final cur = opts.contains(_d[k]) ? _d[k] as String : def;
    _d[k] = cur;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('d_${k}_$cur'),
        initialValue: cur,
        items: [for (final o in opts) DropdownMenuItem(value: o, child: Text(o))],
        onChanged: (v) => setState(() => _d[k] = v),
        decoration: InputDecoration(border: const OutlineInputBorder(), labelText: label),
      ),
    );
  }

  Widget sw(String k, String title, [String? sub]) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: sub == null ? null : Text(sub),
        value: _d[k] == true,
        onChanged: (v) => setState(() => _d[k] = v),
      );

  // ---- per type ----
  List<Widget> _ssh() => [
        tf('host', 'SSH host / IP'),
        tf('port', 'SSH port', type: TextInputType.number, def: '22'),
        tf('user', 'Username'),
        tf('pass', 'Password', obscure: true),
        tf('keyPem', 'Private key (PEM, optional)', lines: 4, mono: true),
        tf('keyPass', 'Key passphrase', obscure: true),
        sw('tls', 'SSL / TLS tunnel (SNI)', 'SSH wrapped in TLS, e.g. stunnel or nginx stream'),
        if (_d['tls'] == true)
          tf('sni', 'SNI', hint: 'cdn.example.com   or   [random=a.com,b.com]  [rotate=...]'),
        tf('proxyHost', 'Remote HTTP proxy host (optional)'),
        tf('proxyPort', 'Remote proxy port', type: TextInputType.number, def: '8080'),
        const Divider(),
        Row(children: [
          Expanded(
              child: Text('Custom payload', style: Theme.of(context).textTheme.titleSmall)),
          TextButton.icon(
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Generator'),
            onPressed: () async {
              final r = await Navigator.push<String>(context,
                  MaterialPageRoute(builder: (_) => const PayloadGeneratorPage(pick: true)));
              if (r != null) setState(() => _payload.text = r);
            },
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _payload,
            minLines: 5,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                labelText: 'Payload (blank = none)',
                hintText: 'GET / [protocol][crlf]Host: [host][crlf]'
                    'Upgrade: websocket[crlf][crlf]'),
          ),
        ),
        sw('ws', 'WebSocket framing after upgrade',
            'Enable only if the server is a framed WS→SSH gateway'),
      ];

  static const _protos = ['vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'socks'];

  List<Widget> _v2() {
    final mode = _d['mode'] == 'link' || _d['mode'] == 'json' ? _d['mode'] as String : 'gui';
    _d['mode'] = mode;
    return [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'gui', label: Text('Manual')),
          ButtonSegment(value: 'link', label: Text('Link')),
          ButtonSegment(value: 'json', label: Text('JSON')),
        ],
        selected: {mode},
        onSelectionChanged: (s) => setState(() => _d['mode'] = s.first),
      ),
      const SizedBox(height: 16),
      if (mode == 'link')
        tf('link', 'vmess:// vless:// trojan:// ss:// hysteria2:// socks:// link', lines: 6, mono: true),
      if (mode == 'json')
        tf('json', 'Full Xray JSON config', lines: 16, mono: true),
      if (mode == 'gui') ..._v2gui(),
    ];
  }

  List<Widget> _v2gui() {
    final proto = _protos.contains(_d['proto']) ? _d['proto'] as String : 'vless';
    final net = (_d['network'] ?? 'tcp') as String;
    final sec = (_d['security'] ?? 'none') as String;
    final web = proto == 'vless' || proto == 'vmess' || proto == 'trojan';
    return [
      dd('proto', 'Protocol', _protos, 'vless'),
      tf('address', 'Server address'),
      tf('port', 'Port', type: TextInputType.number, def: '443'),
      if (proto == 'socks') tf('user', 'Username (optional)'),
      tf('id', proto == 'vless' || proto == 'vmess' ? 'UUID' : 'Password / auth'),
      if (proto == 'vless') ...[
        tf('encryption', 'VLESS encryption', def: 'none'),
        dd('flow', 'Flow', ['none', 'xtls-rprx-vision'], 'none'),
      ],
      if (proto == 'vmess') ...[
        dd('scy', 'VMess security', ['auto', 'aes-128-gcm', 'chacha20-poly1305', 'none'], 'auto'),
        tf('aid', 'Alter ID', type: TextInputType.number, def: '0'),
      ],
      if (proto == 'shadowsocks')
        dd('method', 'Cipher', [
          'aes-256-gcm',
          'aes-128-gcm',
          'chacha20-ietf-poly1305',
          '2022-blake3-aes-128-gcm',
          '2022-blake3-aes-256-gcm',
          '2022-blake3-chacha20-poly1305',
        ], 'aes-256-gcm'),
      if (web) ...[
        dd('network', 'Transport', ['tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'kcp'], 'tcp'),
        if (net == 'ws' || net == 'httpupgrade' || net == 'xhttp') ...[
          tf('host', 'Host header'),
          tf('path', 'Path', def: '/'),
        ],
        if (net == 'grpc') tf('path', 'gRPC service name'),
        if (net == 'kcp') tf('path', 'mKCP seed (optional)'),
        dd('security', 'Security', ['none', 'tls', 'reality'], 'none'),
        if (sec != 'none') ...[
          tf('sni', 'SNI / server name'),
          dd('fp', 'uTLS fingerprint',
              ['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'randomized', 'none'], 'chrome'),
          tf('alpn', 'ALPN (e.g. h2,http/1.1)'),
          tf('pcs', 'Pinned cert SHA-256 (optional)'),
        ],
        if (sec == 'reality') ...[
          tf('pbk', 'REALITY public key'),
          tf('sid', 'REALITY short ID'),
          tf('spx', 'REALITY spiderX'),
        ],
      ],
      if (proto == 'hysteria2') ...[
        tf('sni', 'SNI'),
        tf('obfsPass', 'Salamander obfs password (optional)'),
        tf('mport', 'Port hopping range (e.g. 20000-30000)'),
        tf('pcs', 'Pinned cert SHA-256 (optional)'),
      ],
    ];
  }

  List<Widget> _group() {
    final members = ((_d['members'] as List?) ?? []).map((e) => e.toString()).toList();
    final others = widget.all.where((e) => e.type != ProfileType.group && e.id != p.id);
    if (others.isEmpty) return [const Text('Create some profiles first.')];
    return [
      const Text('Tick servers in the order they should be tried. If one fails, the next is used.'),
      for (final o in others)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: members.contains(o.id),
          title: Text(o.name),
          subtitle: Text(o.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          secondary: members.contains(o.id) ? Text('#${members.indexOf(o.id) + 1}') : null,
          onChanged: (v) => setState(() {
            v == true ? members.add(o.id) : members.remove(o.id);
            _d['members'] = members;
          }),
        ),
    ];
  }

  void _save() {
    final t = _name.text.trim();
    if (t.isNotEmpty) p.name = t;
    if (p.type == ProfileType.ssh) _d['payload'] = _payload.text;
    p.data = _d;
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(typeLabel(p.type)),
          actions: [TextButton(onPressed: _save, child: const Text('Save'))],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'Profile name'),
          ),
          const SizedBox(height: 12),
          ...switch (p.type) {
            ProfileType.ssh => _ssh(),
            ProfileType.v2ray => _v2(),
            ProfileType.wireguard => [
                tf('config', 'WireGuard config (wg-quick format)', lines: 14, mono: true)
              ],
            ProfileType.group => _group(),
          },
        ]),
      );
}
