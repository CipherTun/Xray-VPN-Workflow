# My Tunnel

Standalone multi-protocol tunnel client for Android (Flutter). Everything is configured
by hand in the GUI, or as raw JSON. No dependency on other VPN apps' files.

## Profiles
| Type | Configure by |
|------|--------------|
| SSH Tunnel | Host, port, user/password or key, optional TLS+SNI, optional HTTP proxy, custom payload, WebSocket framing |
| V2Ray / Xray / Hysteria2 | Manual form (VLESS, VMess, Trojan, Shadowsocks, Hysteria2, SOCKS; TCP/WS/gRPC/HTTPUpgrade/XHTTP/mKCP; TLS/REALITY), share link, or full Xray JSON |
| WireGuard | wg-quick config (runs inside the Xray core) |
| Failover Group | Ordered list of other profiles; next is tried if one fails |

Profiles can be exported (JSON to clipboard) and re-imported; pasting a standard share link also works.

## Payload tokens
`[crlf] [cr] [lf] [host] [port] [host_port] [protocol] [ua] [netData]`
`[random=a,b,c]` random pick, `[rotate=a,b,c]` advances every connection (also valid in SNI).
`[split]` `[delay_split]` `[instant_split]` send what follows as a new packet.
SSH order: TCP (proxy or host) -> TLS/SNI -> payload (reply header stripped) -> SSH.

## Settings
DNS changer (Google/Cloudflare/Quad9/AdGuard/custom, IPv6 + fallback), auto-reconnect with backoff,
LAN bypass, per-app bypass (package names), local SOCKS port, SSH keep-alive, hotspot sharing.

## Tools
Payload generator, Host checker (TCP/TLS/SNI/payload test), log viewer.

## Servers
- SSH: any OpenSSH server. TLS mode: put stunnel or nginx `stream` in front. WS mode: a WS->SSH gateway.
- Hysteria2: official server (https://v2.hysteria.network). Standard Hysteria2 only.
- Xray: any standard Xray/V2Ray server.

## Not included (needs native cores that can't be bundled from Dart)
DNSTT/SlowDNS, Psiphon, OpenVPN, ZIVPN/UDP Custom (proprietary Hysteria variants), UDP over SSH (udpgw),
per-profile MTU, "only selected apps" mode.

## Build
Push to GitHub. Actions builds ONE universal APK with armeabi-v7a, arm64-v8a and x86_64
(Flutter cannot build 32-bit x86 release apps). Download from Actions > run > Artifacts.
The APK is debug-signed; sign it yourself for store release.
