#!/usr/bin/env python3
"""
Verify update-manifest signature with OpenSSL public key.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Verify update-manifest signature.")
    p.add_argument("--manifest", required=True, help="Path to update-manifest.json")
    p.add_argument("--signature", required=True, help="Path to detached signature file")
    p.add_argument("--public-key", required=True, help="Path to PEM public key")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    manifest = pathlib.Path(args.manifest)
    signature = pathlib.Path(args.signature)
    public_key = pathlib.Path(args.public_key)

    for p in (manifest, signature, public_key):
        if not p.exists():
            raise RuntimeError(f"Missing required file: {p}")

    cmd = [
        "openssl",
        "dgst",
        "-sha256",
        "-verify",
        str(public_key),
        "-signature",
        str(signature),
        str(manifest),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Signature verification failed: {proc.stderr.strip() or proc.stdout.strip()}")

    print("Signature verification succeeded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

