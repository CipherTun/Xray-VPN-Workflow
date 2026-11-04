#!/usr/bin/env python3
"""Restores "allowInsecure" in the Xray-core build used for libv2ray.aar.

Xray-core removed it: the JSON loader answers with a "removed feature" error and the TLS runtime no longer has an
InsecureSkipVerify switch (config.proto only keeps pinnedPeerCertSha256 and verifyPeerCertByName). This patch needs no
protobuf regeneration. It reuses the existing verifyPeerCertByName list:

  1. infra/conf/transport_security.go: allowInsecure=true adds a reserved marker name to VerifyPeerCertByName
     (instead of failing).
  2. transport/internet/tls/config.go: GetTLSConfig already sets InsecureSkipVerify when that list is non-empty,
     and verifyPeerCert now accepts the chain when it finds the marker. A pinnedPeerCertSha256 on the same profile
     is still enforced first, so pinning always wins over "insecure".

Usage: patch_xray_allow_insecure.py <path to the xray-core checkout>
Every anchor must match exactly once, otherwise the build stops (an Xray update changed the code: re-check the patch).
"""
import pathlib
import sys

if len(sys.argv) != 2:
    sys.exit("usage: patch_xray_allow_insecure.py <xray-core dir>")
root = pathlib.Path(sys.argv[1])
MARKER = "AllowInsecureMarker"


def patch(rel: str, old: str, new: str) -> None:
    path = root / rel
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"{rel}: already patched")
        return
    if text.count(old) != 1:
        sys.exit(f"::error::{rel}: expected anchor found {text.count(old)} times (need exactly 1). Xray-core changed; update this patch.")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"{rel}: patched")


# 1) JSON config: accept allowInsecure instead of raising the removed-feature error.
patch(
    "infra/conf/transport_security.go",
    "\tif c.AllowInsecure {\n"
    "\t\treturn nil, errors.PrintRemovedFeatureError(`\"allowInsecure\"`, `\"pinnedPeerCertSha256\"(pcs) and \"verifyPeerCertByName\"(vcn)`)\n"
    "\t}\n",
    "\tif c.AllowInsecure {\n"
    "\t\t// CipherTun: restored. verifyPeerCert (transport/internet/tls) skips verification when it sees the marker.\n"
    "\t\tconfig.VerifyPeerCertByName = append(config.VerifyPeerCertByName, tls." + MARKER + ")\n"
    "\t}\n",
)

# 2a) The reserved marker name (".invalid" can never be a real certificate name).
patch(
    "transport/internet/tls/config.go",
    "func (r *RandCarrier) verifyPeerCert(",
    "// " + MARKER + " is a reserved entry of VerifyPeerCertByName that stands for allowInsecure.\n"
    "const " + MARKER + " = \"allow-insecure.ciphertun.invalid\"\n\n"
    "func (r *RandCarrier) verifyPeerCert(",
)

# 2b) Accept the chain when the marker is present and nothing is pinned.
patch(
    "transport/internet/tls/config.go",
    "\tif len(certs) == 0 {\n\t\treturn errors.New(\"unexpected certs\")\n\t}\n",
    "\tif len(certs) == 0 {\n\t\treturn errors.New(\"unexpected certs\")\n\t}\n\n"
    "\t// CipherTun: allowInsecure. A pinned certificate (pinnedPeerCertSha256) is still enforced below.\n"
    "\tif r.PinnedPeerCertSha256 == nil {\n"
    "\t\tfor _, n := range r.VerifyPeerCertByName {\n"
    "\t\t\tif n == " + MARKER + " {\n"
    "\t\t\t\treturn nil\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t}\n",
)
