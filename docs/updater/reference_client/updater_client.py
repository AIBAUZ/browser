#!/usr/bin/env python3
"""
Reference updater client for AIBA Browser.

This is designed to be portable and dependency-light:
- stdlib HTTP client
- OpenSSL CLI for signature verification

Integrate the same logic into browser native code.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
from typing import Dict, Optional, Tuple


GITHUB_API = "https://api.github.com"


@dataclasses.dataclass(order=True, frozen=True)
class SemVer:
    major: int
    minor: int
    patch: int
    pre: str = ""

    @staticmethod
    def parse(value: str) -> "SemVer":
        m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$", value)
        if not m:
            raise ValueError(f"Invalid semver: {value}")
        return SemVer(int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4) or "")


def compare_versions(current: str, remote: str) -> bool:
    c = SemVer.parse(current)
    r = SemVer.parse(remote)
    if (r.major, r.minor, r.patch) != (c.major, c.minor, c.patch):
        return (r.major, r.minor, r.patch) > (c.major, c.minor, c.patch)
    # stable > prerelease
    if c.pre and not r.pre:
        return True
    return False


def http_get(url: str, headers: Dict[str, str], timeout: int = 60) -> Tuple[int, Dict[str, str], bytes]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()) if e.headers else {}, e.read()


def platform_key() -> str:
    sys_name = platform.system().lower()
    machine = platform.machine().lower()
    if sys_name == "windows":
        return "windows-arm64" if "arm" in machine else "windows-x64"
    if sys_name == "darwin":
        if machine in {"x86_64", "amd64"}:
            return "macos-x64"
        if machine in {"arm64", "aarch64"}:
            return "macos-arm64"
        return "macos-universal"
    if sys_name == "linux":
        return "linux-arm64" if "arm" in machine else "linux-x64"
    raise RuntimeError(f"Unsupported platform: {sys_name}/{machine}")


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_manifest_signature(manifest_path: pathlib.Path, sig_path: pathlib.Path, pub_key_path: pathlib.Path) -> None:
    cmd = [
        "openssl",
        "dgst",
        "-sha256",
        "-verify",
        str(pub_key_path),
        "-signature",
        str(sig_path),
        str(manifest_path),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Manifest signature verification failed: {proc.stderr.strip() or proc.stdout.strip()}")


def get_release(owner: str, repo: str, token: str, etag: str) -> Tuple[Optional[dict], str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "AIBABrowser-UpdaterReference/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if etag:
        headers["If-None-Match"] = etag

    status, resp_headers, body = http_get(f"{GITHUB_API}/repos/{owner}/{repo}/releases/latest", headers)
    if status == 304:
        return None, etag
    if status != 200:
        raise RuntimeError(f"Release API request failed: status={status}, body={body.decode('utf-8', errors='replace')}")
    payload = json.loads(body.decode("utf-8"))
    return payload, resp_headers.get("ETag", "")


def find_asset_url(release: dict, name: str) -> str:
    for asset in release.get("assets", []):
        if asset.get("name") == name:
            return asset["browser_download_url"]
    raise RuntimeError(f"Required release asset not found: {name}")


def download_to(path: pathlib.Path, url: str, headers: Dict[str, str]) -> None:
    status, _, body = http_get(url, headers)
    if status != 200:
        raise RuntimeError(f"Download failed: {url} (status {status})")
    path.write_bytes(body)


def load_state(state_path: pathlib.Path) -> dict:
    if not state_path.exists():
        return {}
    try:
        return json.loads(state_path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state_path: pathlib.Path, state: dict) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    p = argparse.ArgumentParser(description="AIBA Browser updater reference client.")
    p.add_argument("--repo", default="AIBAUZ/browser", help="GitHub repository OWNER/REPO")
    p.add_argument("--current-version", required=True, help="Current app version, e.g. 1.0.0")
    p.add_argument("--public-key", required=True, help="Pinned updater public key PEM")
    p.add_argument("--cache-dir", default="", help="Cache directory")
    p.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""), help="Optional GitHub token")
    args = p.parse_args()

    owner, repo = args.repo.split("/", 1)
    cache_dir = pathlib.Path(args.cache_dir) if args.cache_dir else pathlib.Path.home() / ".aiba_updater"
    cache_dir.mkdir(parents=True, exist_ok=True)
    state_path = cache_dir / "state.json"
    state = load_state(state_path)
    etag = state.get("latest_release_etag", "")

    release, new_etag = get_release(owner, repo, args.token, etag)
    if release is None:
        print("No update metadata changes (HTTP 304).")
        return 0

    latest = release.get("tag_name", "")
    if not latest:
        raise RuntimeError("Missing tag_name in release payload.")
    if not compare_versions(args.current_version, latest):
        state["latest_release_etag"] = new_etag
        save_state(state_path, state)
        print(f"No update. current={args.current_version}, latest={latest}")
        return 0

    headers = {
        "Accept": "application/octet-stream",
        "User-Agent": "AIBABrowser-UpdaterReference/1.0",
    }
    if args.token:
        headers["Authorization"] = f"Bearer {args.token}"

    manifest_url = find_asset_url(release, "update-manifest.json")
    sig_url = find_asset_url(release, "update-manifest.sig")

    with tempfile.TemporaryDirectory(prefix="aiba-update-") as td:
        tmp = pathlib.Path(td)
        manifest_path = tmp / "update-manifest.json"
        sig_path = tmp / "update-manifest.sig"
        download_to(manifest_path, manifest_url, headers)
        download_to(sig_path, sig_url, headers)

        verify_manifest_signature(manifest_path, sig_path, pathlib.Path(args.public_key))
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        key = platform_key()
        if key not in manifest["assets"]:
            raise RuntimeError(f"No asset for current platform: {key}")
        asset = manifest["assets"][key]

        out_dir = cache_dir / manifest["version"]
        out_dir.mkdir(parents=True, exist_ok=True)
        installer_path = out_dir / asset["name"]
        download_to(installer_path, asset["download_url"], headers)

        digest = sha256_file(installer_path)
        if digest != asset["sha256"]:
            raise RuntimeError(
                f"SHA mismatch for {installer_path.name}: expected={asset['sha256']} actual={digest}"
            )

        # At this point:
        # 1) manifest is signed and verified
        # 2) installer hash is verified
        # Next: run OS-specific signature validation and installer handoff.
        print(f"Update downloaded and verified: {installer_path}")

    state["latest_release_etag"] = new_etag
    save_state(state_path, state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

