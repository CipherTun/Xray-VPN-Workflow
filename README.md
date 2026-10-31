# XRay VPN

Flutter VPN client for **Android and iOS**, package / bundle id **`io.surprise.vpn`**.

| Piece | Version | Notes |
|---|---|---|
| Xray-core | **v26.10.21** (latest release, 21 Oct 2026) | Emergency security update that drops compromised root certificates. v26.10.10 and v26.10.17 were withdrawn upstream. |
| libXray | v26.9.9 tag, rebuilt against the commit above | Official XTLS gomobile wrapper (AAR / xcframework) |
| DartSSH2 | **4.1.0** (`dartssh2: ^4.1.0`) | Dynamic forwarding (`ssh -D`) powers the SSH profile type |
| Flutter | 3.27 or newer | |

## How it works

```
 Flutter UI ──MethodChannel──► Android: XRayVpnService (VpnService)     iOS: PacketTunnelProvider
                                   │ establish() → TUN fd                    │ utun fd
                                   ▼                                         ▼
                         Xray-core `tun` inbound (xray.tun.fd) ── routing ── proxy outbound
                                                                         │
                  VLESS / VMess / Trojan / Shadowsocks (+Reality, TLS, WS, gRPC, XHTTP, HTTPUpgrade, Mux, fragment)
                                                                         │
                  SSH profile: DartSSH2 opens a session and a local SOCKS5 port; Xray's outbound points at it
```

* **TUN mode**: the platform creates the TUN device and Xray-core consumes it directly. No tun2socks helper.
* The app is excluded from its own VPN on Android so Xray and SSH sockets never loop. The Tools tab reaches the tunnel through a local HTTP inbound (`socksPort + 1`).

## Setup

```bash
./scripts/setup.sh                 # flutter create + overlay + gradle patch
./scripts/build_cores.sh android   # libXray.aar → android/app/libs
./scripts/build_cores.sh geo       # geoip.dat / geosite.dat (needed for the ad-block rule)
flutter run
```

### iOS (manual Xcode steps, Apple does not allow scripting these)
1. Open `ios/Runner.xcworkspace`. **File → New → Target → Network Extension → Packet Tunnel Provider**, name it `PacketTunnel`, bundle id `io.surprise.vpn.PacketTunnel`.
2. Replace the generated files with `ios/PacketTunnel/*` (provider, Info.plist, entitlements).
3. Add the **Network Extensions (Packet Tunnel)** and **App Groups** capabilities to *both* targets, group `group.io.surprise.vpn`. Set `Runner.entitlements` as Runner's entitlements file.
4. `./scripts/build_cores.sh ios`, add `LibXray.xcframework` to both targets.
5. Needs a paid Apple Developer account and a real device (the simulator cannot run packet tunnels).

## Build from your phone with GitHub Actions (no PC needed)

1. On github.com create a **private** repository (private keeps your signing key and shared configs safe).
2. **Add file → Create new file**, name it `.github/workflows/build-android.yml` and paste the contents of `build-android.yml` (shipped next to this zip). Commit.
3. **Add file → Upload files**, upload `xray_vpn.zip` to the repository root, commit to `main`. The workflow unpacks the zip itself, so you never need to extract anything.
4. Open the **Actions** tab → *Build Android APK*. The first run takes ~15-25 minutes (it compiles Xray-core into `libXray.aar`; later runs reuse the cache). You can also tap *Run workflow* and pick `debug` for a faster test build.
5. When it is green, open the run and download the **XRayVPN-apks** artifact. Unzip it with your phone's file manager and install `XRayVPN-arm64-v8a.apk` (most phones) or the universal APK.
6. To update: upload a new `xray_vpn.zip` (same name, replace) and the build runs again. Push a tag like `v1.0.1` to get the APKs attached to a GitHub Release.

**Signing.** Without secrets the workflow creates a signing key once and caches it, so updates install over each other. GitHub deletes caches that go unused for 7 days; if that happens, uninstall the old app before installing the new build. For a permanent key add repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.

**Icons.** `scripts/make_icons.py` drew the launcher icon (tick dial + bolt, adaptive and Android 13 themed layers); the workflow turns them into every size with `flutter_launcher_icons`. The status-bar icon is a vector shield with a bolt cut-out.

iOS is not built by the workflow: the Packet Tunnel extension target has to be added in Xcode and an unsigned build cannot be installed without a Mac or sideloading tool.

## Sharing configs

Open a server → **Share…**. Configs travel as an encrypted package (AES-256-GCM): a `xrayvpn://import?d=…` link, a QR code or a `.xrcfg` file.

**Locking is automatic.** Switch on *Lock config* and the receiver gets a config whose server address and credentials are hidden in the UI and logs, with editing, copying and exporting disabled. No PIN, phone passcode or password is involved, same as other provider apps. (The app PIN in Settings → Security is a separate privacy feature for opening XRay itself.)

Presets: *Open*, *Locked*, *Trial* (1 day, 500 MB, 1 h sessions, no root) and *Monthly* (30 days, 20 GB). Every option can be changed:

* **Message** and sender name shown to the receiver on import and on the Dashboard
* **Validity**: fixed date, or N days counted from the receiver's first import
* **Protection**: block re-sharing, hide from screenshots, block rooted phones, lock to one device ID (Settings → About)
* **Limits**: maximum session length and total data, enforced by the receiving app
* **Live preview** of exactly what the receiver will see
* **Advanced**: an optional password that encrypts the file for one specific person

If someone re-shares a config they received (when allowed), expiry, data, session, root and lock limits can only be kept or tightened, never loosened.

Honest limits: the app has to hand the real credentials to the VPN core to connect, so a lock stops casual viewing, copying and editing, not someone who controls a rooted phone. Expiry and data counters live on the receiver's phone, so they can be defeated by changing the clock or wiping app data.

## Settings map

| Page | Highlights |
|---|---|
| Connection | Kill switch, auto-reconnect, smart connect, auto-disconnect timer, IPv6, MTU, per-app VPN |
| Routing & rules | Rules editor (drag to reorder, rule tester, presets), direct for a country, block QUIC/BitTorrent, domain strategy, in-app geo file updates |
| DNS | Providers, DoH, custom servers, FakeDNS, static hosts, query strategy, cache |
| Xray / V2Ray core | Sniffing, Mux/XUDP, TLS fragmentation, uTLS fingerprint, TCP Fast Open/MPTCP, failover and load balancing (balancer + observatory), double-hop chain, share on LAN with optional login, JSON override, copy generated config |
| SSH | Keep-alive, timeouts, no-delay, host key policy (trust on first use / manual approval / off) with a trusted-hosts manager, jump host, per-server transports: direct, TLS with custom SNI, HTTP payload |
| Android | Wake lock levels, battery exemption, boot start, real-network tracking, LAN exclusion, bypass control, notification privacy, Always-on VPN, Data Saver, diagnostics, launcher shortcuts and Quick Settings tile |
| Security & privacy | App PIN with lock delay, block screenshots, clear logs, erase all data |
| Data & backup | Daily and monthly caps, usage history, subscriptions, encrypted server backup, settings export and import |

## Permissions (Android)
`INTERNET`, `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` (Android 14), `POST_NOTIFICATIONS` (requested at connect time), `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, and the service-level `BIND_VPN_SERVICE`. The system VPN consent dialog is shown through `VpnService.prepare()` on first connect. Always-on VPN and "Block connections without VPN" are supported through the system settings (Settings → System VPN settings shortcut).

## Features
Dashboard dial with live throughput, Configs (paste, subscriptions, manual editor, latency test, favorites, swipe to delete, share link), Logs (filter, copy), Tools (public IP, speed test, latency, DoH lookup, export), Settings (themes, 6 accents + custom colour picker, blur strength, routing modes, kill switch, auto-reconnect, connect on launch, IPv6, MTU, DNS, per-app VPN on Android, sniffing, Mux, TLS fragmentation, log level, SSH keep-alive and host-key reset), Quick Settings tile (Android), foreground notification with Disconnect, SSH trust-on-first-use host key pinning.

## More features
Strong wake lock (CPU + Wi-Fi lock with watchdog renewal, three levels), battery-optimisation prompt, start on boot, network-change aware tunnel, Quick Settings tile, speed in the notification, smart "fastest server" connect, subscription auto-update, data usage history with monthly cap warning, auto-disconnect timer, DNS presets (incl. DoH), QUIC blocking, custom routing rules, PIN app lock, encrypted backup and restore.

## Known limits (read before shipping)
* **Not compiled in the environment that produced this code.** I had no Flutter/Android/Xcode toolchain or network, so expect a first-build fix-up pass.
* libXray changed its public API several times in 2026. `XrayCore.kt` and `PacketTunnelProvider.swift` follow the README of the 26.x `Invoke` API; if your tag differs, only those two files need changes. Same for the Xray `tun` inbound settings in `xray_config.dart`.
* The SSH profile runs in the Flutter engine. It survives backgrounding while the VPN foreground service keeps the process alive, but swiping the app away ends the engine and the SSH session; auto-reconnect then cannot restart it. For always-on SSH, move DartSSH2 into a headless Dart isolate or the service.
* Android traffic counters use device-level `TrafficStats` (the app itself is excluded from the VPN), so numbers are approximate. iOS shows status only.
* Per-app VPN is Android only. iOS extensions are limited to about 50 MB of RAM.
* The Play Store restricts VPN apps (declaration form, no data harvesting) and `systemExempted` foreground services; App Store requires an organisation account for Network Extension VPNs.
