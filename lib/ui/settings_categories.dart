part of 'settings_page.dart';

// ───────── shared helpers ─────────

/// Multi-line text editor dialog bound to a setting. [json] validates before saving.
Future<void> _textDialog(
  BuildContext context, {
  required String k,
  required String title,
  String? help,
  bool json = false,
  int lines = 8,
}) async {
  final s = context.read<AppState>();
  final ctl = TextEditingController(text: s.settings.get<String>(k));
  String? err;
  final r = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (help != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(help, style: const TextStyle(fontSize: 12.5, height: 1.4))),
            TextField(
              controller: ctl,
              minLines: lines,
              maxLines: lines + 4,
              autocorrect: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: InputDecoration(errorText: err, filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none)),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          if (ctl.text.isNotEmpty) TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Clear')),
          FilledButton(
            onPressed: () {
              if (json && ctl.text.trim().isNotEmpty) {
                try {
                  if (jsonDecode(ctl.text) is! Map) throw const FormatException('Top level must be an object { … }');
                } on FormatException catch (e) {
                  setS(() => err = e.message);
                  return;
                }
              }
              Navigator.pop(c, ctl.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (r != null) s.setSetting(k, r);
}

/// Bottom sheet to pick servers. [multi] allows several (kept in the order they were ticked); [where] filters the list.
Future<void> _pickServers(
  BuildContext context, {
  required String title,
  required bool multi,
  required Set<String> selected,
  bool Function(ServerConfig)? where,
  required void Function(Set<String>) onDone,
}) async {
  final s = context.read<AppState>();
  final list = s.configs.where(where ?? (_) => true).toList();
  if (list.isEmpty) {
    toast(context, 'No suitable servers yet.');
    return;
  }
  final chosen = {...selected};
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        maxChildSize: .92,
        builder: (_, ctl) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 4),
            child: Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              if (!multi && chosen.isNotEmpty) TextButton(onPressed: () { onDone({}); Navigator.pop(ctx); }, child: const Text('None')),
              if (multi) FilledButton(onPressed: () { onDone(chosen); Navigator.pop(ctx); }, child: const Text('Done')),
            ]),
          ),
          Expanded(
            child: ListView(controller: ctl, children: [
              for (final c in list)
                CheckboxListTile(
                  value: chosen.contains(c.id),
                  title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${c.proto.label} · ${c.safeHost}'),
                  onChanged: (v) {
                    if (!multi) {
                      onDone({c.id});
                      Navigator.pop(ctx);
                      return;
                    }
                    setS(() => v == true ? chosen.add(c.id) : chosen.remove(c.id));
                  },
                ),
            ]),
          ),
        ]),
      ),
    ),
  );
}

/// Row that opens a multi-line editor.
class _TextRow extends StatelessWidget {
  const _TextRow(this.title, this.k, {this.help, this.empty = 'Not set', this.json = false});
  final String title, k, empty;
  final String? help;
  final bool json;
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final v = s.settings.get<String>(k).trim();
    return _Row(
      title: title,
      subtitle: v.isEmpty ? empty : '${v.split('\n').length} line(s)',
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _textDialog(context, k: k, title: title, help: help, json: json),
    );
  }
}

// ───────── Appearance ─────────

class _AppearancePage extends StatelessWidget {
  const _AppearancePage();
  @override
  Widget build(BuildContext context) => _SubPage('Appearance', (c) {
        final s = c.read<AppState>();
        final p = c.pal;
        return [
          _Section('Look', [
            _Row(
              title: 'Theme',
              trailing: SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, selectedBackgroundColor: p.accentSoft, selectedForegroundColor: p.accent),
                segments: const [ButtonSegment(value: 0, label: Text('Auto')), ButtonSegment(value: 1, label: Text('Light')), ButtonSegment(value: 2, label: Text('Dark'))],
                selected: {s.settings.get<int>('themeMode')},
                onSelectionChanged: (v) => s.setSetting('themeMode', v.first),
              ),
            ),
            _AccentPicker(),
            _SliderRow(title: 'Glass blur', value: s.settings.get<double>('blur'), min: 0, max: 40, onChanged: (v) => s.setSetting('blur', v)),
            _SwitchRow('Haptic feedback', null, 'haptics'),
          ]),
        ];
      });
}

// ───────── Connection ─────────

class _ConnectionPage extends StatelessWidget {
  const _ConnectionPage();
  @override
  Widget build(BuildContext context) => _SubPage('Connection', (c) {
        final s = c.read<AppState>();
        final set = s.settings;
        final perApp = set.get<String>('perAppMode');
        return [
          _Section('Reliability', [
            _SwitchRow('Kill switch', 'Keep traffic blocked if the tunnel drops instead of falling back to the open network', 'killSwitch'),
            _SwitchRow('Auto-reconnect', 'Retry up to 5 times when the connection drops', 'autoReconnect'),
            _SwitchRow('Connect on launch', null, 'autoConnect'),
            _SwitchRow('Smart connect', 'Test every server and pick the fastest on connect', 'smartConnect'),
            _ValueRow('Server connect timeout (s)', 'connectTimeout', number: true),
            _IntChoiceRow('Auto-disconnect timer', 'sleepTimer', const {0: 'Off', 30: '30 min', 60: '1 h', 120: '2 h', 240: '4 h'}),
          ]),
          _Section('Network', [
            _SwitchRow('IPv6', 'Route IPv6 through the tunnel', 'ipv6'),
            _ValueRow('MTU', 'mtu', number: true),
          ]),
          _Section('Per-app VPN', [
            _ChoiceRow('Mode', 'perAppMode', const {'off': 'All apps', 'exclude': 'Exclude apps', 'only': 'Only apps'}),
            if (perApp != 'off')
              _Row(
                title: perApp == 'only' ? 'Apps using the VPN' : 'Apps bypassing the VPN',
                subtitle: '${set.list('perApps').length} selected',
                onTap: () => _appPicker(c),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
          ]),
        ];
      });
}

// ───────── Routing ─────────

class _RoutingPage extends StatelessWidget {
  const _RoutingPage();
  @override
  Widget build(BuildContext context) => _SubPage('Routing & rules', (c) {
        final s = c.read<AppState>();
        final n = s.settings.get<String>('customRules').split('\n').where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#')).length;
        return [
          _Section('What goes through the tunnel', [
            _ChoiceRow('Mode', 'routing', const {'global': 'Everything', 'bypassLan': 'Skip LAN', 'bypassLanAds': 'Skip LAN + ads'}),
            _ChoiceRow('Direct for a country', 'bypassCountry', const {'none': 'Off', 'cn': 'China', 'ir': 'Iran', 'ru': 'Russia'}),
            _ChoiceRow('Domain strategy', 'domainStrategy', const {'AsIs': 'As is', 'IPIfNonMatch': 'IP if no match', 'IPOnDemand': 'IP on demand'}),
          ]),
          _Section('Blocking', [
            _SwitchRow('Block QUIC (UDP 443)', 'Forces browsers onto TCP, which proxies handle better', 'blockQuic'),
            _SwitchRow('Block BitTorrent', 'Drops torrent traffic. Needs traffic sniffing (Tunnel core).', 'blockBittorrent'),
          ]),
          _Section('Rules', [
            _Row(
              title: 'Rules editor',
              subtitle: n == 0 ? 'Add per-domain, per-IP, per-port rules' : '$n rule${n == 1 ? '' : 's'} · first match wins',
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const _RulesEditorPage())),
            ),
            _Row(
              title: 'Route lists',
              subtitle: 'Country IPs, China sites and the ad list used by geo rules',
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const _ListsPage())),
            ),
          ]),
        ];
      });
}

class _RulesEditorPage extends StatefulWidget {
  const _RulesEditorPage();
  @override
  State<_RulesEditorPage> createState() => _RulesEditorState();
}

class _RulesEditorState extends State<_RulesEditorPage> {
  late List<String> lines = context.read<AppState>().settings.get<String>('customRules').split('\n').where((l) => l.trim().isNotEmpty).toList();
  final test = TextEditingController();
  String? testResult;

  void _save() => context.read<AppState>().setSetting('customRules', lines.join('\n'));

  static bool _isRule(String l) => RegExp(r'^(proxy|direct|block)\s', caseSensitive: false).hasMatch(l.trim());

  Color _color(XPalette p, String l) => switch (l.trim().split(RegExp(r'\s')).first.toLowerCase()) {
        'direct' => p.good,
        'block' => p.bad,
        _ => p.accent,
      };

  Future<void> _edit(int? i) async {
    final p = context.pal;
    var action = 'direct', type = 'domain';
    final val = TextEditingController();
    if (i != null && _isRule(lines[i])) {
      final parts = lines[i].trim().split(RegExp(r'\s+'));
      action = parts.first.toLowerCase();
      val.text = parts.skip(1).join(' ');
    }
    const types = {
      'domain': 'Domain (and subdomains)',
      'full': 'Exact domain',
      'keyword': 'Keyword',
      'geosite': 'Geosite list (cn, category-ads-all)',
      'ip': 'IP / CIDR',
      'geoip': 'Country IPs (geoip)',
      'port': 'Port or range',
      'protocol': 'Protocol',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: Text(i == null ? 'New rule' : 'Edit rule'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, children: [
                for (final a in const ['proxy', 'direct', 'block'])
                  ChoiceChip(label: Text(a), selected: action == a, onSelected: (_) => setS(() => action = a), selectedColor: alpha(_color(p, a), .25)),
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Match', filled: true),
                items: [for (final e in types.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setS(() => type = v ?? type),
              ),
              const SizedBox(height: 10),
              TextField(controller: val, autocorrect: false, decoration: const InputDecoration(labelText: 'Values (comma separated)', hintText: 'example.com, bank.example', filled: true)),
              const SizedBox(height: 6),
              Text(i != null && _isRule(lines[i]) ? 'Existing prefixes such as domain: are kept as typed.' : 'The prefix is added for you.', style: const TextStyle(fontSize: 12)),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save'))],
        ),
      ),
    );
    if (ok != true || val.text.trim().isEmpty) return;
    final toks = val.text.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).map((t) => t.contains(':') ? t : '$type:$t').join(' ');
    setState(() {
      final line = '$action $toks';
      i == null ? lines.add(line) : lines[i] = line;
    });
    _save();
  }

  void _preset(String line) {
    setState(() => lines.add(line));
    _save();
  }

  /// Which rule would catch this domain? Only domain-style selectors can be simulated here.
  void _runTest() {
    final d = test.text.trim().toLowerCase();
    if (d.isEmpty) return;
    for (final l in lines) {
      if (!_isRule(l)) continue;
      final parts = l.trim().split(RegExp(r'\s+'));
      for (final t in parts.skip(1)) {
        final x = t.contains(':') ? t.substring(t.indexOf(':') + 1).toLowerCase() : t.toLowerCase();
        final kind = t.contains(':') ? t.substring(0, t.indexOf(':')) : 'domain';
        final hit = switch (kind) {
          'domain' => d == x || d.endsWith('.$x'),
          'full' => d == x,
          'keyword' => d.contains(x),
          _ => false,
        };
        if (hit) {
          setState(() => testResult = '${parts.first.toUpperCase()} · matched "$t"');
          return;
        }
      }
    }
    setState(() => testResult = 'No custom rule matches. The default route applies.');
  }

  @override
  void dispose() {
    test.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_rounded)),
                const Expanded(child: Text('Rules editor', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5))),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.auto_fix_high_rounded),
                  tooltip: 'Presets',
                  onSelected: (v) {
                    if (v == 'text') {
                      _textDialog(context, k: 'customRules', title: 'Rules as text', help: 'One rule per line: proxy, direct or block, then selectors.\nExamples:\ndirect domain:bank.com full:login.example.com\nblock geosite:category-ads-all\ndirect geoip:cn geosite:cn\ndirect ip:192.168.0.0/16 port:22', lines: 8).then((_) => setState(() => lines = context.read<AppState>().settings.get<String>('customRules').split('\n').where((l) => l.trim().isNotEmpty).toList()));
                    } else {
                      _preset(v);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'block geosite:category-ads-all', child: Text('Block ads')),
                    PopupMenuItem(value: 'block protocol:bittorrent', child: Text('Block BitTorrent')),
                    PopupMenuItem(value: 'direct domain:local domain:lan domain:localhost', child: Text('Local names direct')),
                    PopupMenuItem(value: 'direct geoip:cn geosite:cn', child: Text('China direct')),
                    PopupMenuItem(value: 'direct port:22', child: Text('SSH port direct')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'text', child: Text('Edit as text')),
                  ],
                ),
                IconButton(onPressed: () => _edit(null), icon: const Icon(Icons.add_rounded), tooltip: 'Add rule'),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(children: [
                  Expanded(child: TextField(controller: test, autocorrect: false, onSubmitted: (_) => _runTest(), decoration: const InputDecoration(hintText: 'Test a domain, e.g. news.example.com', border: InputBorder.none, isDense: true))),
                  IconButton(onPressed: _runTest, icon: Icon(Icons.play_arrow_rounded, color: p.accent)),
                ]),
              ),
            ),
            if (testResult != null) Padding(padding: const EdgeInsets.fromLTRB(26, 0, 26, 6), child: Align(alignment: Alignment.centerLeft, child: Text(testResult!, style: TextStyle(color: p.accent, fontWeight: FontWeight.w700, fontSize: 13)))),
            Expanded(
              child: lines.isEmpty
                  ? const Center(child: EmptyState(icon: Icons.alt_route_rounded, title: 'No custom rules', body: 'Rules are checked top to bottom and the first match decides. Tap + or use the presets menu.'))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
                      itemCount: lines.length,
                      onReorder: (a, b) {
                        setState(() {
                          if (b > a) b--;
                          lines.insert(b, lines.removeAt(a));
                        });
                        _save();
                      },
                      itemBuilder: (_, i) {
                        final l = lines[i];
                        final rule = _isRule(l);
                        final action = rule ? l.trim().split(RegExp(r'\s')).first.toLowerCase() : '#';
                        return Padding(
                          key: ValueKey('$i$l'),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Dismissible(
                            key: ValueKey('d$i$l'),
                            background: Container(decoration: BoxDecoration(color: alpha(p.bad, .25), borderRadius: BorderRadius.circular(24)), alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 22), child: Icon(Icons.delete_rounded, color: p.bad)),
                            direction: DismissDirection.endToStart,
                            onDismissed: (_) {
                              setState(() => lines.removeAt(i));
                              _save();
                            },
                            child: Glass(
                              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                              onTap: rule ? () => _edit(i) : null,
                              child: Row(children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                  decoration: BoxDecoration(color: alpha(rule ? _color(p, l) : p.dim, .18), borderRadius: BorderRadius.circular(99)),
                                  child: Text(action.toUpperCase(), style: TextStyle(color: rule ? _color(p, l) : p.dim, fontWeight: FontWeight.w800, fontSize: 11)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(child: Text(rule ? l.trim().split(RegExp(r'\s+')).skip(1).join('  ') : l, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: rule ? p.text : p.dim))),
                                ReorderableDragStartListener(index: i, child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.drag_handle_rounded, color: p.dim))),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The text lists behind geoip:XX / geosite:XX rules. The tunnel library bundles no country data, so the app
/// downloads these files and the VPN service hands them to the library when it starts.
class _ListsPage extends StatefulWidget {
  const _ListsPage();
  @override
  State<_ListsPage> createState() => _ListsState();
}

class _ListsState extends State<_ListsPage> {
  Map<String, String> info = {};
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final s = context.read<AppState>();
    final m = await RouteLists.status(routeListSources(s.settings).keys);
    if (mounted) setState(() => info = m);
  }

  Future<void> _refresh() async {
    final s = context.read<AppState>();
    setState(() { busy = true; error = null; });
    try {
      await s.refreshRouteLists();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
    _scan();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _SubPage(
      'Route lists',
      (c) => [
        _Section('In use by your routing', [
          if (info.isEmpty) const _Row(title: 'None', subtitle: 'Your current routing needs no downloaded list.'),
          for (final e in info.entries) _Row(title: e.key, subtitle: e.value),
        ]),
        _Section('Sources', [
          _ValueRow('Ad domains URL', 'listAdsUrl'),
          _ValueRow('China domains URL', 'listDirectUrl'),
          _ValueRow('Country IP lists base URL', 'listIpBase'),
          _ValueRow('Refresh every (days)', 'listRefreshDays', number: true),
        ]),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: p.bad))),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text('Lists are plain text, one domain or CIDR per line. They are downloaded before the tunnel starts and applied on connect, so a change takes effect the next time you connect. Default source: Loyalsoldier.', style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.4)),
        ),
      ],
      actions: [
        busy
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh_rounded), tooltip: 'Download again'),
      ],
    );
  }
}

// ───────── DNS ─────────

class _DnsPage extends StatelessWidget {
  const _DnsPage();
  @override
  Widget build(BuildContext context) => _SubPage('DNS', (c) {
        final s = c.read<AppState>();
        final custom = s.settings.get<String>('dnsPreset') == 'custom';
        return [
          _Section('Resolver', [
            _ChoiceRow('Provider', 'dnsPreset', const {'cloudflare': 'Cloudflare', 'google': 'Google', 'quad9': 'Quad9', 'adguard': 'AdGuard', 'custom': 'Custom'}),
            if (custom) _ValueRow('Primary DNS', 'dns1'),
            if (custom) _ValueRow('Secondary DNS', 'dns2'),
          ]),
          _Section('Behaviour', [
            _SwitchRow('FakeDNS', 'Answer instantly with placeholder IPs and resolve on the server side (faster, avoids DNS leaks, makes domain rules work for every app)', 'fakeDns'),
            _ValueRow('Direct resolver (host:port)', 'directDns'),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text('The provider answers the tunnel\'s DNS queries. The direct resolver looks up your server\'s own hostname and domains your rules send direct; it bypasses the VPN so it works before the tunnel is up.', style: TextStyle(color: c.pal.dim, fontSize: 12.5, height: 1.4)),
          ),
        ];
      });
}

// ───────── Tunnel core ─────────

class _TunnelPage extends StatelessWidget {
  const _TunnelPage();
  @override
  Widget build(BuildContext context) => _SubPage('Tunnel core', (c) {
        final s = c.read<AppState>();
        final set = s.settings;
        final pool = set.list('failoverIds');
        final ordered = set.get<String>('failoverMode') == 'ordered';
        return [
          _Section('Sniffing', [
            _SwitchRow('Traffic sniffing', 'Read the domain or protocol from the first bytes so domain and protocol rules work', 'sniffing'),
          ]),
          _Section('Multiplexing', [
            _SwitchRow('Mux', 'Share one connection between streams (VLESS, VMess, Trojan, Shadowsocks; not with XTLS flows)', 'mux'),
            _ValueRow('Mux concurrency', 'muxConcurrency', number: true),
          ]),
          _Section('Anti-censorship', [
            _SwitchRow('TLS fragmentation', 'Split the TLS hello to evade filtering (TLS and REALITY profiles)', 'fragment'),
            if (set.get<bool>('fragment')) ...[
              _ValueRow('Fragment length', 'fragLength'),
              _ValueRow('Fragment interval (ms)', 'fragInterval'),
            ],
            _ChoiceRow('TLS fingerprint (uTLS)', 'defaultFp', const {'': 'Per server', 'chrome': 'Chrome', 'firefox': 'Firefox', 'safari': 'Safari', 'ios': 'iOS', 'android': 'Android', 'edge': 'Edge', 'randomized': 'Randomized'}),
            _SwitchRow('Allow insecure TLS', 'Skips certificate checks. Only for servers you control', 'allowInsecure'),
          ]),
          _Section('UDP over TCP proxies', [
            _ValueRow('BadVPN udpgw address', 'udpgw'),
            const _Row(title: 'What this does', subtitle: 'SSH, SOCKS and HTTP proxies cannot carry UDP on their own. If the server runs badvpn-udpgw, enter its address as the server sees it (for example 127.0.0.1:7300) to tunnel UDP, DNS included.'),
          ]),
          _Section('Failover', [
            _ChoiceRow('Mode', 'failoverMode', const {'off': 'Off', 'ordered': 'Try backups in order'}),
            if (ordered)
              _Row(
                title: 'Backup servers',
                subtitle: pool.isEmpty ? 'Pick the servers to try, in the order you tick them' : '${pool.length} selected · tried in this order',
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickServers(c, title: 'Backup servers (in order)', multi: true, selected: pool.toSet(), where: (x) => x.id != s.selectedId, onDone: (v) => s.setSetting('failoverIds', v.toList())),
              ),
            const _Row(title: 'How it works', subtitle: 'When the selected server cannot be reached within the connect timeout, the library moves to the next backup. Backups keep their own protocol and credentials; routing, DNS and UDP gateway settings come from this phone.'),
          ]),
          _Section('SSH profiles', [
            const _Row(title: 'Host key pinning', subtitle: 'Set a host key fingerprint per SSH server in Configs → Edit. Without one the key is not verified.'),
            const _Row(title: 'Key passphrases', subtitle: 'Not supported by the tunnel library. Use an unencrypted private key.'),
          ]),
          _Section('Advanced', [
            _Row(
              title: 'Copy generated config',
              subtitle: 'V2-TUN JSON for the selected server',
              trailing: const Icon(Icons.copy_rounded, size: 19),
              onTap: () {
                final sel = s.selected;
                if (sel == null) return toast(c, 'Select a server first.');
                if (sel.locked) return toast(c, 'Locked configs cannot be exported.');
                try {
                  Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(s.configFor(sel))));
                  toast(c, 'Config copied');
                } catch (e) {
                  toast(c, '$e');
                }
              },
            ),
          ]),
        ];
      });
}

// ───────── Android ─────────

class _AndroidPage extends StatelessWidget {
  const _AndroidPage();
  @override
  Widget build(BuildContext context) => _SubPage('Android', (c) {
        final s = c.read<AppState>();
        void guard(Future<void> f) => f.catchError((_) => toast(c, 'Not available on this device.'));
        return [
          _Section('Stay connected', [
            _ChoiceRow('Wake lock strength', 'wakeMode', const {'off': 'Off', 'balanced': 'CPU only', 'strong': 'CPU + Wi-Fi + watchdog'}),
            _Row(title: 'Allow unrestricted battery use', subtitle: 'Stops Doze and app standby from pausing the tunnel', trailing: const Icon(Icons.battery_charging_full_rounded, size: 20), onTap: () => guard(s.bridge.requestIgnoreBattery())),
            _Row(title: 'Battery optimisation list', subtitle: 'Review all apps', trailing: const Icon(Icons.open_in_new_rounded, size: 19), onTap: () => guard(s.bridge.openBatterySettings())),
            _SwitchRow('Start on boot', 'Reconnect after the phone restarts (needs VPN permission granted once)', 'bootStart'),
            _Row(title: 'Data Saver', subtitle: 'Exempt XRay so background data is not cut', trailing: const Icon(Icons.open_in_new_rounded, size: 19), onTap: () => guard(s.bridge.openDataSaverSettings())),
          ]),
          _Section('Network', [
            _SwitchRow('Track the real network', 'Tell Android which Wi-Fi or mobile network carries the tunnel (better handover, correct metering)', 'useUnderlying'),
            _SwitchRow('Keep LAN outside the tunnel', 'Local devices, printers and casting keep working (Android 13+)', 'excludeLan'),
            _SwitchRow('Let apps bypass the VPN', 'Apps may opt out of the tunnel themselves. Less private.', 'allowBypass'),
            _Row(title: 'Always-on VPN and lockdown', subtitle: 'Open system VPN settings', trailing: const Icon(Icons.open_in_new_rounded, size: 19), onTap: () => guard(s.bridge.openSystemVpnSettings())),
          ]),
          _Section('Notification', [
            _SwitchRow('Show server name', 'Locked configs never show it', 'notifShowServer'),
            _SwitchRow('Hide details on lock screen', 'Shows only that the VPN is on', 'notifHideLock'),
            _Row(title: 'Notification channel settings', trailing: const Icon(Icons.open_in_new_rounded, size: 19), onTap: () => guard(s.bridge.openNotificationSettings())),
          ]),
          _Section('Health', [
            _Row(title: 'Diagnostics', subtitle: 'Check permissions, battery, network and route lists', trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const _DiagnosticsPage()))),
          ]),
        ];
      });
}

class _DiagnosticsPage extends StatefulWidget {
  const _DiagnosticsPage();
  @override
  State<_DiagnosticsPage> createState() => _DiagnosticsState();
}

class _DiagnosticsState extends State<_DiagnosticsPage> {
  List<(String, String, bool?)> rows = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final s = context.read<AppState>();
    final d = await s.bridge.diagnostics();
    final lists = await RouteLists.status(routeListSources(s.settings).keys);
    final missing = lists.entries.where((e) => e.value == 'Not downloaded').map((e) => e.key).toList();
    final r = <(String, String, bool?)>[
      ('Android', '${d['release'] ?? '?'} (API ${d['sdk'] ?? '?'})', null),
      ('Device', '${d['device'] ?? '?'} · ${d['abi'] ?? '?'}', null),
      ('VPN permission', d['vpnGranted'] == true ? 'Granted' : 'Not granted yet. It is asked on first connect.', d['vpnGranted'] == true),
      ('Notifications', d['notifications'] == true ? 'Enabled' : 'Disabled. The connection notice may be hidden.', d['notifications'] == true),
      ('Battery optimisation', d['batteryExempt'] == true ? 'XRay is exempt' : 'XRay may be paused in the background. Fix it in Android settings.', d['batteryExempt'] == true),
      ('Data Saver', switch (d['dataSaver']) { 1 => 'Off', 2 => 'On, XRay allowed', 3 => 'On and XRay is restricted', _ => 'Unknown' }, d['dataSaver'] == null ? null : d['dataSaver'] != 3),
      ('Rooted', d['rooted'] == true ? 'Yes' : 'No', null),
      ('Tunnel service', d['running'] == true ? 'Running' : 'Stopped', null),
      ('Route lists', lists.isEmpty ? 'None needed' : (missing.isEmpty ? '${lists.length} ready' : 'Missing: ${missing.join(', ')}. They download on the next connect.'), lists.isEmpty ? null : missing.isEmpty),
      ('Servers', '${s.configs.length} saved', s.configs.isNotEmpty),
    ];
    if (mounted) setState(() { rows = r; loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return _SubPage(
      'Diagnostics',
      (c) => [
        if (loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
        if (!loading)
          _Section('Checks', [
            for (final (k, v, ok) in rows)
              _Row(
                title: k,
                subtitle: v,
                trailing: ok == null ? null : Icon(ok ? Icons.check_circle_rounded : Icons.warning_amber_rounded, color: ok ? p.good : p.warn, size: 22),
              ),
          ]),
        if (!loading)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy report'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: rows.map((r) => '${r.$1}: ${r.$2}').join('\n')));
                toast(c, 'Report copied');
              },
            ),
          ),
      ],
      actions: [IconButton(onPressed: () { setState(() => loading = true); _run(); }, icon: const Icon(Icons.refresh_rounded))],
    );
  }
}

// ───────── Security ─────────

class _SecurityPage extends StatelessWidget {
  const _SecurityPage();
  @override
  Widget build(BuildContext context) => _SubPage('Security & privacy', (c) {
        final s = c.read<AppState>();
        final has = s.settings.get<String>('pin').isNotEmpty;
        return [
          _Section('App lock', [
            _Row(
              title: has ? 'Change or remove PIN' : 'Set app PIN',
              subtitle: 'Ask for a PIN when XRay opens. Shared configs lock automatically and never need this PIN.',
              trailing: Icon(has ? Icons.lock_rounded : Icons.lock_open_rounded, size: 20),
              onTap: () => _pinDialog(c),
            ),
            if (has) _IntChoiceRow('Lock again after', 'autoLockSec', const {0: 'Immediately', 30: '30 s', 60: '1 min', 300: '5 min'}),
          ]),
          _Section('Privacy', [
            _SwitchRow('Block screenshots', 'Hide XRay from screenshots, screen recording and the recent-apps preview', 'secureScreen'),
            _SwitchRow('Clear logs on disconnect', null, 'clearLogsOnDisconnect'),
          ]),
          _Section('Config import', [
            _Row(title: 'Import a config', subtitle: 'File, link or text', trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const ImportPage()))),
          ]),
          _Section('Danger zone', [
            _Row(
              title: 'Erase all data',
              subtitle: 'Servers, settings, usage, route lists and PIN. Cannot be undone.',
              trailing: Icon(Icons.delete_forever_rounded, color: c.pal.bad),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: c,
                  builder: (d) => AlertDialog(
                    title: const Text('Erase everything?'),
                    content: const Text('All servers (including locked configs), settings, usage history and downloaded route lists will be removed from this phone.'),
                    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Erase'))],
                  ),
                );
                if (ok == true) {
                  await s.wipeAll();
                  if (c.mounted) toast(c, 'All data erased');
                }
              },
            ),
          ]),
        ];
      });
}

// ───────── Data & backup ─────────

class _DataPage extends StatelessWidget {
  const _DataPage();
  @override
  Widget build(BuildContext context) => _SubPage('Data & backup', (c) {
        final s = c.read<AppState>();
        return [
          _Section('Usage', [
            _Row(title: 'This month', trailing: Text(fmtBytes(s.monthBytes()), style: TextStyle(color: c.pal.accent, fontWeight: FontWeight.w800))),
            _ValueRow('Daily warning (MB, 0 = off)', 'dailyCapMb', number: true),
            _ValueRow('Monthly warning (MB, 0 = off)', 'monthlyCapMb', number: true),
            _Row(title: 'Clear usage history', onTap: () { s.clearUsage(); toast(c, 'Usage cleared'); }),
          ]),
          _Section('Subscriptions', [
            _ValueRow('Refresh every (hours)', 'subRefreshHours', number: true),
            _Row(
              title: 'Update now',
              subtitle: '${s.subs.length} subscription${s.subs.length == 1 ? '' : 's'}',
              trailing: const Icon(Icons.sync_rounded, size: 20),
              onTap: () async {
                toast(c, 'Updating…');
                await s.refreshSubscriptions(force: true);
                if (c.mounted) toast(c, 'Subscriptions updated');
              },
            ),
          ]),
          _Section('Backup', [
            _Row(title: 'Back up servers', subtitle: 'Creates an encrypted file with every server you may share', trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const SharePage(selectAll: true)))),
            _Row(title: 'Restore from a file or link', trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const ImportPage()))),
            _Row(
              title: 'Copy settings',
              subtitle: 'All options as JSON (no servers, no PIN)',
              trailing: const Icon(Icons.copy_rounded, size: 19),
              onTap: () {
                Clipboard.setData(ClipboardData(text: s.exportSettings()));
                toast(c, 'Settings copied');
              },
            ),
            _Row(
              title: 'Paste settings',
              subtitle: 'Apply settings copied from another phone',
              trailing: const Icon(Icons.paste_rounded, size: 19),
              onTap: () async {
                final t = (await Clipboard.getData('text/plain'))?.text ?? '';
                try {
                  final n = s.importSettings(t);
                  if (c.mounted) toast(c, 'Applied $n setting${n == 1 ? '' : 's'}');
                } catch (_) {
                  if (c.mounted) toast(c, 'The clipboard does not contain XRay settings.');
                }
              },
            ),
          ]),
        ];
      });
}

// ───────── About ─────────

class _AboutPage extends StatelessWidget {
  const _AboutPage();
  @override
  Widget build(BuildContext context) => _SubPage('About', (c) {
        final s = c.read<AppState>();
        return [
          _Section('XRay VPN', [
            const _Row(title: 'Version', subtitle: 'io.surprise.vpn · 1.2.0'),
            _Row(title: 'Device ID', subtitle: s.deviceCode, trailing: const Icon(Icons.copy_rounded, size: 19), onTap: () { Clipboard.setData(ClipboardData(text: s.deviceCode)); toast(c, 'Device ID copied'); }),
            const _Row(title: 'Tunnel library', subtitle: 'V2-TUN (VLESS, VMess, Trojan, Shadowsocks, SSH, SOCKS, HTTP, Hysteria)'),
          ]),
          _Section('Maintenance', [
            _Row(title: 'Reset settings', subtitle: 'Servers are kept', onTap: () => _confirmReset(c)),
          ]),
        ];
      });
}
