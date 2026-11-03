#!/usr/bin/env python3
from pathlib import Path
import sys
if len(sys.argv) != 2:
    raise SystemExit("usage: patch_xray_core.py PATH_TO_XRAY_CORE")
source = Path(sys.argv[1]) / "infra/conf/xray.go"
if not source.is_file():
    raise SystemExit(f"Xray source file not found: {source}")
text = source.read_text(encoding="utf-8")
start_marker = "func validateOutboundTransportSecurity("
end_marker = "// validateXDrive"
start = text.find(start_marker)
if start < 0:
    raise SystemExit("Could not find validator; refusing a blind patch.")
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("Could not find validator boundary; refusing a blind patch.")
replacement = """// validateOutboundTransportSecurity is intentionally permissive in this
// client build. CipherTun supports legacy VLESS and Trojan profiles that use
// plaintext transport security (security=none), including public endpoints.
// The server must still be configured for the exact same protocol/transport.
// This does not add encryption: users should prefer TLS, REALITY, or VLESS
// Encryption whenever the server supports them.
func validateOutboundTransportSecurity(rawConfig interface{}, senderSettings *proxyman.SenderConfig) error {
    return nil
}

"""
patched = text[:start] + replacement + text[end:]
if patched == text:
    raise SystemExit("Patch made no changes.")
source.write_text(patched, encoding="utf-8")
print(f"Patched {source}")
