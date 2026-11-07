import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/v2tun_config.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Options of the V2-TUN library that have no place in the normal server editor or settings: global ones (idle
/// timeout, latency ordering of the failover list) and per-server ones for the selected profile (WebSocket
/// keepalive and headers, XHTTP tuning, payload reply handling, SSH algorithms and double hop, proxy headers).
/// Every value is stored as a profile parameter or a setting and reaches the library through buildV2tunConfig.
class LibraryOptionsPage extends StatefulWidget {
  const LibraryOptionsPage({super.key});
  @override
  State<LibraryOptionsPage> createState() => _LibraryOptionsState();
}

class _LibraryOptionsState extends State<LibraryOptionsPage> {
  static const _keys = [
    'wsPing', 'wsHeaders', 'xPadding', 'xMaxPost', 'xMinInterval',
    'payloadMethod', 'payloadUA', 'expectCodes', 'expectResponses', 'payloadVars',
    'proxyHeaders',
    'sshCiphers', 'sshKex', 'sshMacs', 'sshHostKeys',
    'sshNextServer', 'sshNextUser', 'sshNextPass', 'sshNextKey', 'sshNextHostKey',
  ];

  late final ServerConfig? c = context.read<AppState>().selected;
  late final Map<String, TextEditingController> t = {
    for (final k in _keys) k: TextEditingController(text: c?.p(k) ?? ''),
  };
  late final TextEditingController idle = TextEditingController(text: '${context.read<AppState>().settings.get<int>('idleTimeout')}');
  late final TextEditingController sort = TextEditingController(text: '${context.read<AppState>().settings.get<int>('latencySort')}');
  late String expect = c?.p('expectResponse', 'auto') ?? 'auto';
  bool busy = false;

  @override
  void dispose() {
    for (final x in t.values) {
      x.dispose();
    }
    idle.dispose();
    sort.dispose();
    super.dispose();
  }

  Widget _f(String k, String label, {int lines = 1, bool obscure = false, TextInputType? type, String? hint}) => Padding(
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

  Widget _num(TextEditingController ctl, String label, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label, hintText: hint, filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
        ),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, style: TextStyle(color: context.pal.dim, fontSize: 12, height: 1.4)),
      );

  Widget _section(String title, List<Widget> children) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Glass(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color: p.accent, fontWeight: FontWeight.w800, fontSize: 14.5)),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }

  int _seconds(TextEditingController ctl) {
    final v = int.tryParse(ctl.text.trim()) ?? 0;
    return v < 0 ? 0 : v;
  }

  Future<void> _save() async {
    final s = context.read<AppState>();
    final sel = c;
    setState(() => busy = true);
    s.setSetting('idleTimeout', _seconds(idle));
    s.setSetting('latencySort', _seconds(sort));
    if (sel != null && !sel.locked) {
      for (final k in _keys) {
        final v = t[k]!.text.trim();
        if (v.isEmpty) {
          sel.params.remove(k);
        } else {
          sel.params[k] = v;
        }
      }
      if (expect == 'auto') {
        sel.params.remove('expectResponse');
      } else {
        sel.params['expectResponse'] = expect;
      }
      s.upsert(sel);
    }
    // Ask the library whether it accepts the result, so a typo shows up here and not on the next connect.
    String msg = 'Saved';
    if (sel != null) {
      try {
        final err = await s.bridge.validateConfig(jsonEncode(s.configFor(sel, quiet: true)));
        msg = err == null ? 'Saved. The library accepts the config.' : 'Saved, but the library says: $err';
      } on V2tunConfigError catch (e) {
        msg = 'Saved, but: ${e.message}';
      }
    }
    if (!mounted) return;
    setState(() => busy = false);
    toast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final sel = c;
    final editable = sel != null && !sel.locked;
    final net = (sel?.p('net', 'tcp') ?? 'tcp').toLowerCase();
    final hy = sel?.proto.isHysteria ?? false;
    final ssh = sel?.proto == Proto.ssh;
    final httpProxy = sel?.proto == Proto.http || sel?.proto == Proto.https;
    final hasPayload = (sel?.p('payload') ?? '').isNotEmpty;
    final hdrNet = !hy && const {'ws', 'httpupgrade', 'h2', 'http', 'xhttp', 'splithttp'}.contains(net);
    final xhttp = !hy && (net == 'xhttp' || net == 'splithttp');
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_rounded)),
                const Expanded(child: Text('Library options', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5))),
              ]),
            ),
            Expanded(
              child: ListView(padding: EdgeInsets.fromLTRB(20, 8, 20, 40 + MediaQuery.of(context).viewInsets.bottom), children: [
                _section('All servers', [
                  _num(idle, 'Idle timeout (seconds, 0 = never)', hint: '0'),
                  _note('Closes a tunneled connection after this long without data in either direction.'),
                  _num(sort, 'Failover latency check (seconds, 0 = listed order)', hint: '0'),
                  _note('With failover servers, measures how fast each one accepts a connection every N seconds and, after a failure, tries the quickest first. Hysteria servers cannot be measured this way.'),
                ]),
                if (sel == null)
                  const Padding(padding: EdgeInsets.all(8), child: Text('Select a server in Configs to edit its options.'))
                else if (!editable)
                  const Padding(padding: EdgeInsets.all(8), child: Text('The selected server is locked, so its options cannot be changed.'))
                else ...[
                  Padding(padding: const EdgeInsets.only(left: 4, bottom: 10), child: Text('Selected server: ${sel.name}', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700))),
                  if (net == 'ws' && !hy)
                    _section('WebSocket keepalive', [
                      _f('wsPing', 'Ping every (seconds, blank = off)', type: TextInputType.number),
                      _note('Sends a WebSocket ping so carriers and CDNs do not drop an idle tunnel.'),
                    ]),
                  if (hdrNet)
                    _section('Extra request headers', [
                      _f('wsHeaders', 'One per line: Name: value', lines: 3),
                      _note('Added to the WebSocket, HTTP upgrade, HTTP/2 or XHTTP request.'),
                    ]),
                  if (xhttp)
                    _section('XHTTP tuning', [
                      _f('xPadding', 'Padding bytes (min-max, blank = default 100-1000)', hint: '100-1000'),
                      _f('xMaxPost', 'Largest upload piece (bytes, blank = default)', type: TextInputType.number),
                      _f('xMinInterval', 'Minimum gap between uploads (ms, blank = default)', type: TextInputType.number),
                    ]),
                  if (hasPayload)
                    _section('Payload', [
                      _f('payloadMethod', 'Value for [method]', hint: 'GET'),
                      _f('payloadUA', 'Value for [ua]'),
                      _f('payloadVars', 'Variables, one per line: name=value (used as [var=name])', lines: 3),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Read the server\'s HTTP reply', style: TextStyle(color: p.dim, fontWeight: FontWeight.w700, fontSize: 12.5)),
                          const SizedBox(height: 6),
                          Wrap(spacing: 8, children: [
                            for (final o in const {'auto': 'Automatic', 'yes': 'Always', 'no': 'Never'}.entries)
                              ChoiceChip(label: Text(o.value), selected: expect == o.key, onSelected: (_) => setState(() => expect = o.key)),
                          ]),
                        ]),
                      ),
                      _f('expectResponses', 'Replies to read (blank = one per request line)', type: TextInputType.number),
                      _f('expectCodes', 'Accepted status codes (comma separated, 0 = any)', hint: '101, 200'),
                      _note('Automatic reads and drops the reply when the payload is an HTTP request on a plain connection or goes through a proxy. Without a list, 101 and any 2xx are accepted.'),
                    ]),
                  if (httpProxy)
                    _section('Proxy headers', [
                      _f('proxyHeaders', 'One per line: Name: value', lines: 3),
                      _note('Extra headers sent with the CONNECT request to the proxy.'),
                    ]),
                  if (ssh) ...[
                    _section('SSH algorithms', [
                      _f('sshCiphers', 'Ciphers (comma separated)', hint: 'aes128-ctr, chacha20-poly1305@openssh.com'),
                      _f('sshKex', 'Key exchanges', hint: 'curve25519-sha256'),
                      _f('sshMacs', 'MACs', hint: 'hmac-sha2-256'),
                      _f('sshHostKeys', 'Host key algorithms', hint: 'ssh-ed25519'),
                      _note('Leave empty for the library\'s maximum-compatibility defaults. Use these to talk to old servers or to narrow what is offered.'),
                    ]),
                    _section('Double hop', [
                      _note('This server becomes the jump host. The second server below is reached from inside its session and is where your traffic exits.'),
                      _f('sshNextServer', 'Second server (host:port as the jump host reaches it)', hint: '10.0.0.5:22'),
                      _f('sshNextUser', 'Second server username'),
                      _f('sshNextPass', 'Second server password', obscure: true),
                      _f('sshNextKey', 'Second server private key (PEM, optional)', lines: 3),
                      _f('sshNextHostKey', 'Second server host key pin (SHA256:…)', hint: 'SHA256:…'),
                    ]),
                  ],
                  if (!hasPayload && !ssh && !httpProxy && !hdrNet && !xhttp && net != 'ws')
                    _note('This server type has no extra options. Payload options appear once the server has a payload, SSH options for SSH servers, header options for WebSocket, HTTP/2 and XHTTP transports.'),
                ],
                FilledButton(
                  onPressed: busy ? null : _save,
                  style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                  child: Text(busy ? 'Checking…' : 'Save', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
