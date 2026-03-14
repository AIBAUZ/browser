#!/usr/bin/env python3
"""
Sign update manifest with OpenSSL private key.
"""

from __future__ import annotations

import argparse
import base64
import os
import pathlib
import subprocess
import tempfile


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Sign update-manifest.json using OpenSSL private key.")
    p.add_argument("--manifest", required=True, help="Path to update-manifest.json")
    p.add_argument("--signature", default="update-manifest.sig", help="Output signature file path (binary)")
    p.add_argument("--signature-b64", default="", help="Optional base64 output path")
    p.add_argument(
        "--private-key-file",
        default="",
        help="Path to PEM private key file. If omitted, read from --private-key-env variable.",
    )
    p.add_argument(
        "--private-key-env",
        default="UPDATER_SIGNING_PRIVATE_KEY_PEM",
        help="Env var containing PEM private key material.",
    )
    return p.parse_args()


def read_private_key_to_temp_file(path: str, env_name: str) -> str:
    if path:
        pem_path = pathlib.Path(path)
        if not pem_path.exists():
            raise RuntimeError(f"Private key file not found: {pem_path}")
        return str(pem_path)

    pem = os.environ.get(env_name, "")
    if not pem.strip():
        raise RuntimeError(f"Private key is missing. Set {env_name} or provide --private-key-file.")

    tmp = tempfile.NamedTemporaryFile(prefix="updater-key-", suffix=".pem", delete=False)
    tmp.write(pem.encode("utf-8"))
    tmp.flush()
    tmp.close()
    return tmp.name


def main() -> int:
    args = parse_args()
    manifest = pathlib.Path(args.manifest)
    if not manifest.exists():
        raise RuntimeError(f"Manifest not found: {manifest}")

    key_file = read_private_key_to_temp_file(args.private_key_file, args.private_key_env)
    signature = pathlib.Path(args.signature)
    try:
        cmd = [
            "openssl",
            "dgst",
            "-sha256",
            "-sign",
            key_file,
            "-out",
            str(signature),
            str(manifest),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"OpenSSL signing failed: {proc.stderr.strip()}")

        if args.signature_b64:
            sig_b64 = base64.b64encode(signature.read_bytes()).decode("ascii")
            pathlib.Path(args.signature_b64).write_text(sig_b64 + "\n", encoding="utf-8")

        print(f"Signed {manifest} -> {signature}")
        return 0
    finally:
        # Remove temporary key file when key came from env var.
        if not args.private_key_file:
            try:
                pathlib.Path(key_file).unlink(missing_ok=True)
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())

