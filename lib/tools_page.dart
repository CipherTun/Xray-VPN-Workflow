import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ssh_tunnel.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tools')),
        body: ListView(children: [
          ListTile(
            leading: const Icon(Icons.auto_fix_high),
            title: const Text('Payload generator'),
            subtitle: const Text('Build a custom HTTP payload'),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const PayloadGeneratorPage())),
          ),
          ListTile(
            leading: const Icon(Icons.travel_explore),
            title: const Text('Host checker'),
            subtitle: const Text('Test a host / SNI / payload'),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const HostCheckerPage())),
          ),
        ]),
      );
}

class PayloadGeneratorPage extends StatefulWidget {
  const PayloadGeneratorPage({super.key, this.pick = false});
  final bool pick;
  @override
  State<PayloadGeneratorPage> createState() => _PayloadGeneratorPageState();
}

class _PayloadGeneratorPageState extends State<PayloadGeneratorPage> {
  String _method = 'GET';
  final _path = TextEditingController(text: '/');
  final _host = TextEditingController(text: '[host]');
  final _extra = TextEditingController();
  bool _ws = false, _keep = true, _ua = true, _online = false, _forward = false, _split = false;

  String _generate() {
    final host = _host.text.trim().isEmpty ? '[host]' : _host.text.trim();
    final b = StringBuffer();
    final target = _method == 'CONNECT' ? '[host_port]' : (_path.text.trim().isEmpty ? '/' : _path.text.trim());
    b.write('$_method $target [protocol][crlf]Host: $host[crlf]');
    if (_ws) {
      b.write('Upgrade: websocket[crlf]Connection: Upgrade[crlf]'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==[crlf]Sec-WebSocket-Version: 13[crlf]');
    } else if (_keep) {
      b.write('Connection: Keep-Alive[crlf]');
    }
    if (_online) b.write('X-Online-Host: $host[crlf]');
    if (_forward) b.write('X-Forward-Host: $host[crlf]');
    if (_ua) b.write('User-Agent: [ua][crlf]');
    for (final l in _extra.text.split('\n')) {
      if (l.trim().isNotEmpty) b.write('${l.trim()}[crlf]');
    }
    b.write('[crlf]');
    if (_split) b.write('[split]CONNECT [host_port] [protocol][crlf][crlf]');
    return b.toString();
  }

  Widget _sw(String t, bool v, ValueChanged<bool> f) => SwitchListTile(
      dense: true, contentPadding: EdgeInsets.zero, title: Text(t), value: v, onChanged: (x) => setState(() => f(x)));

  @override
  Widget build(BuildContext context) {
    final out = _generate();
    return Scaffold(
      appBar: AppBar(title: const Text('Payload generator')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          initialValue: _method,
          items: [
            for (final m in ['GET', 'CONNECT', 'POST', 'HEAD', 'PUT', 'PATCH', 'OPTIONS', 'DELETE'])
              DropdownMenuItem(value: m, child: Text(m))
          ],
          onChanged: (v) => setState(() => _method = v!),
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Method'),
        ),
        const SizedBox(height: 12),
        TextField(
            controller: _path,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Path')),
        const SizedBox(height: 12),
        TextField(
            controller: _host,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Host header',
                hintText: '[host] or a front domain; [random=a,b] works too')),
        const SizedBox(height: 8),
        _sw('WebSocket upgrade', _ws, (v) => _ws = v),
        _sw('Keep-Alive', _keep, (v) => _keep = v),
        _sw('User-Agent', _ua, (v) => _ua = v),
        _sw('X-Online-Host', _online, (v) => _online = v),
        _sw('X-Forward-Host', _forward, (v) => _forward = v),
        _sw('Split: front request, then CONNECT', _split, (v) => _split = v),
        TextField(
            controller: _extra,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Extra headers (one per line)',
                alignLabelWithHint: true)),
        const SizedBox(height: 16),
        Text('Result', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(out, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: out));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Copied')));
              },
              child: const Text('Copy'),
            ),
          ),
          if (widget.pick) ...[
            const SizedBox(width: 12),
            Expanded(
                child: FilledButton(
                    onPressed: () => Navigator.pop(context, out), child: const Text('Use'))),
          ],
        ]),
      ]),
    );
  }
}

class HostCheckerPage extends StatefulWidget {
  const HostCheckerPage({super.key});
  @override
  State<HostCheckerPage> createState() => _HostCheckerPageState();
}

class _HostCheckerPageState extends State<HostCheckerPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '443');
  final _sni = TextEditingController();
  final _payload = TextEditingController();
  bool _tls = true;
  bool _busy = false;
  String _result = '';

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _result = 'Testing…';
    });
    final r = await hostCheck(
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 443,
      tls: _tls,
      sni: _sni.text.trim(),
      payload: _payload.text,
    );
    if (mounted) setState(() {
      _busy = false;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Host checker')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
              controller: _host,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Host / IP')),
          const SizedBox(height: 12),
          TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Port')),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('TLS'),
              value: _tls,
              onChanged: (v) => setState(() => _tls = v)),
          if (_tls)
            TextField(
                controller: _sni,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), labelText: 'SNI (blank = host)')),
          const SizedBox(height: 12),
          TextField(
              controller: _payload,
              minLines: 3,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Payload (blank = plain GET)',
                  alignLabelWithHint: true)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _run, child: const Text('Test')),
          const SizedBox(height: 16),
          SelectableText(_result, style: const TextStyle(fontFamily: 'monospace')),
        ]),
      );
}
