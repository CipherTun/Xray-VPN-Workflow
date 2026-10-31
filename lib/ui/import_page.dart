import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/config_package.dart';
import '../core/link_parser.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Import from a pasted link, a shared `.xrcfg` file, plain share links or a subscription URL.
class ImportPage extends StatefulWidget {
  const ImportPage({super.key, this.initialText});
  final String? initialText;
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final text = TextEditingController();
  final pass = TextEditingController();
  Map<String, dynamic>? env;
  ConfigPackage? pkg;
  bool askPassword = false;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null) {
      text.text = widget.initialText!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _process());
    }
  }

  @override
  void dispose() {
    text.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    if (d?.text != null) {
      setState(() => text.text = d!.text!);
      _process();
    }
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles();
    final path = r?.files.single.path;
    if (path == null) return;
    try {
      setState(() => text.text = File(path).readAsStringSync());
      _process();
    } catch (_) {
      setState(() => error = 'Could not read that file.');
    }
  }

  Future<void> _process() async {
    final s = context.read<AppState>();
    final t = text.text.trim();
    setState(() { error = null; pkg = null; askPassword = false; });
    if (t.isEmpty) return;

    env = ConfigPackage.peek(t);
    if (env != null) {
      setState(() => busy = true);
      try {
        pkg = await ConfigPackage.decode(env!, password: pass.text);
      } on NeedsPassword {
        askPassword = true;
      } on ImportException catch (e) {
        error = e.message;
      }
      if (mounted) setState(() => busy = false);
      return;
    }
    if (t.startsWith('http://') || t.startsWith('https://')) {
      setState(() => busy = true);
      try {
        final n = await s.importSubscription(t);
        if (!mounted) return;
        toast(context, n == 0 ? 'The subscription had no supported links.' : 'Added $n server${n == 1 ? '' : 's'} from the subscription');
        if (n > 0) Navigator.pop(context);
      } catch (e) {
        error = 'Download failed: $e';
      }
      if (mounted) setState(() => busy = false);
      return;
    }
    final n = s.importText(t);
    if (!mounted) return;
    if (n == 0) {
      setState(() => error = 'No supported config found. Expected a config file, an xrayvpn:// link, a vless/vmess/trojan/ss/ssh link or a subscription URL.');
    } else {
      toast(context, 'Added $n server${n == 1 ? '' : 's'}');
      Navigator.pop(context);
    }
  }

  Future<void> _add() async {
    try {
      if (pkg!.meta.blockRooted && await context.read<AppState>().bridge.isRooted()) {
        throw ImportException('This config cannot be used on a rooted device.');
      }
      final list = await context.read<AppState>().importPackage(pkg!);
      if (!mounted) return;
      toast(context, 'Added ${list.length} server${list.length == 1 ? '' : 's'}');
      Navigator.pop(context);
    } on ImportException catch (e) {
      setState(() => error = e.message);
    }
  }

  String _fmt(DateTime d) => d.toLocal().toString().substring(0, 16);

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = context.watch<AppState>();
    final m = pkg?.meta;
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_rounded)),
                const Text('Import config', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5)),
              ]),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), children: [
                Glass(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TextField(
                      controller: text,
                      minLines: 4,
                      maxLines: 6,
                      autocorrect: false,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(hintText: 'Paste an xrayvpn:// link, config text, share links or a subscription URL', filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
                    ),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste_rounded, size: 18), label: const Text('Paste')),
                      OutlinedButton.icon(onPressed: _pickFile, icon: const Icon(Icons.folder_open_rounded, size: 18), label: const Text('Open file')),
                      FilledButton(
                        onPressed: busy || text.text.trim().isEmpty ? null : _process,
                        style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent),
                        child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Import'),
                      ),
                    ]),
                  ]),
                ),
                if (askPassword)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Glass(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('This config is password protected', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 10),
                        TextField(controller: pass, obscureText: true, decoration: InputDecoration(labelText: 'Password', filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)), onSubmitted: (_) => _process()),
                        const SizedBox(height: 10),
                        FilledButton(onPressed: _process, style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent), child: const Text('Unlock')),
                      ]),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Glass(tint: alpha(p.bad, .14), child: Row(children: [Icon(Icons.error_outline_rounded, color: p.bad), const SizedBox(width: 12), Expanded(child: Text(error!, style: const TextStyle(height: 1.4)))])),
                  ),
                if (m != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Glass(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m.title.isEmpty ? (pkg!.profiles.length == 1 ? pkg!.profiles.first.name : '${pkg!.profiles.length} servers') : m.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        if (m.author.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text('From ${m.author}', style: TextStyle(color: p.dim))),
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          Pill('${pkg!.profiles.length} server${pkg!.profiles.length == 1 ? '' : 's'}', icon: Icons.dns_rounded),
                          if (m.locked) const Pill('Locked', icon: Icons.lock_rounded),
                          if (m.expiresAt != null) Pill('Expires ${_fmt(m.expiresAt!).substring(0, 10)}', icon: Icons.timer_outlined, color: p.warn),
                          if (m.validDays != null) Pill('Valid ${m.validDays} day${m.validDays == 1 ? '' : 's'} after import', icon: Icons.timer_outlined, color: p.warn),
                          if (m.deviceHash != null) Pill('Bound to a device', icon: Icons.phone_android_rounded),
                          if (!m.allowReshare) const Pill('No re-sharing', icon: Icons.block_rounded),
                          if (m.dataLimitMb != null) Pill(m.dataLimitMb! >= 1024 ? '${(m.dataLimitMb! / 1024).toStringAsFixed(m.dataLimitMb! % 1024 == 0 ? 0 : 1)} GB data' : '${m.dataLimitMb} MB data', icon: Icons.data_usage_rounded, color: p.steel),
                          if (m.maxSessionMin != null) Pill('${m.maxSessionMin} min sessions', icon: Icons.schedule_rounded, color: p.steel),
                          if (m.blockRooted) const Pill('No rooted phones', icon: Icons.security_rounded),
                          if (m.secure) const Pill('Screenshots blocked', icon: Icons.screenshot_monitor_rounded),
                        ]),
                        if (m.note.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(16)),
                            child: Text(m.note, style: const TextStyle(height: 1.45)),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _add,
                          icon: const Icon(Icons.download_done_rounded),
                          label: const Text('Add to my configs', style: TextStyle(fontWeight: FontWeight.w800)),
                          style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.onAccent, padding: const EdgeInsets.symmetric(vertical: 14)),
                        ),
                      ]),
                    ),
                  ),
                const SizedBox(height: 18),
                Glass(
                  child: Row(children: [
                    Icon(Icons.fingerprint_rounded, color: p.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Your Device ID', style: TextStyle(fontWeight: FontWeight.w800)),
                        Text(s.deviceCode, style: TextStyle(color: p.accent, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                        const SizedBox(height: 2),
                        Text('Send this to the sender if they want to lock a config to your phone.', style: TextStyle(color: p.dim, fontSize: 12.5, height: 1.35)),
                      ]),
                    ),
                    IconButton(onPressed: () { Clipboard.setData(ClipboardData(text: s.deviceCode)); toast(context, 'Device ID copied'); }, icon: const Icon(Icons.copy_rounded)),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
