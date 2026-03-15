#!/usr/bin/env python3
"""
Build update-manifest.json from GitHub release assets.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional


GITHUB_API = "https://api.github.com"
SKIP_ASSET_NAMES = {"update-manifest.json", "update-manifest.sig", "update-manifest.sig.b64"}
REQUEST_TIMEOUT_SEC = 60


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate AIBA browser update manifest from GitHub Release assets.")
    p.add_argument("--repo", required=True, help="GitHub repo in OWNER/REPO format.")
    p.add_argument("--tag", required=True, help="Release tag, e.g. v1.2.3.")
    p.add_argument("--token", default="", help="GitHub token (or use GITHUB_TOKEN env).")
    p.add_argument("--channel", default="stable", choices=["stable", "beta"], help="Release channel.")
    p.add_argument(
        "--rules",
        default=str(pathlib.Path(__file__).resolve().parent / "platform_rules.json"),
        help="Path to platform mapping rules JSON.",
    )
    p.add_argument("--output", default="update-manifest.json", help="Output manifest path.")
    p.add_argument("--retries", type=int, default=3, help="HTTP retry count for transient failures.")
    return p.parse_args()


def github_headers(token: str) -> Dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "AIBABrowser-UpdateManifestBuilder/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def http_json(url: str, headers: Dict[str, str], retries: int) -> Dict[str, Any]:
    if not url.startswith("https://"):
        raise RuntimeError(f"Refusing non-HTTPS URL: {url}")
    attempt = 0
    while True:
        attempt += 1
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SEC) as resp:
                payload = resp.read()
                return json.loads(payload.decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            if e.code in {500, 502, 503, 504} and attempt <= retries:
                time.sleep(2 ** (attempt - 1))
                continue
            raise RuntimeError(f"GitHub API error ({e.code}) for {url}: {body}") from e
        except urllib.error.URLError as e:
            if attempt <= retries:
                time.sleep(2 ** (attempt - 1))
                continue
            raise RuntimeError(f"Network error for {url}: {e}") from e


def detect_installer_type(name: str, fallback: str) -> str:
    lower = name.lower()
    if lower.endswith(".msi"):
        return "msi"
    if lower.endswith(".exe"):
        return "exe"
    if lower.endswith(".pkg"):
        return "pkg"
    if lower.endswith(".dmg"):
        return "dmg"
    if lower.endswith(".deb"):
        return "deb"
    if lower.endswith(".rpm"):
        return "rpm"
    if lower.endswith(".appimage"):
        return "appimage"
    if lower.endswith(".tar.gz"):
        return "tar.gz"
    return fallback


def load_rules(path: str) -> List[Dict[str, str]]:
    raw = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    rules: List[Dict[str, str]] = []
    for rule in raw:
        rules.append(
            {
                "pattern": rule["pattern"],
                "platform": rule["platform"],
                "os": rule["os"],
                "arch": rule["arch"],
                "installer": rule["installer"],
            }
        )
    return rules


def classify_asset(name: str, rules: List[Dict[str, str]]) -> Optional[Dict[str, str]]:
    for rule in rules:
        if re.search(rule["pattern"], name):
            installer = detect_installer_type(name, rule["installer"])
            return {
                "platform": rule["platform"],
                "os": rule["os"],
                "arch": rule["arch"],
                "installer": installer,
            }
    return None


def sha256_from_url(url: str, headers: Dict[str, str], retries: int) -> str:
    if not url.startswith("https://"):
        raise RuntimeError(f"Refusing non-HTTPS download URL: {url}")
    attempt = 0
    while True:
        attempt += 1
        req = urllib.request.Request(url, headers=headers, method="GET")
        h = hashlib.sha256()
        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SEC) as resp:
                while True:
                    chunk = resp.read(1024 * 1024)
                    if not chunk:
                        break
                    h.update(chunk)
            return h.hexdigest()
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            if e.code in {500, 502, 503, 504} and attempt <= retries:
                time.sleep(2 ** (attempt - 1))
                continue
            raise RuntimeError(f"Asset download error ({e.code}) for {url}: {body}") from e
        except urllib.error.URLError as e:
            if attempt <= retries:
                time.sleep(2 ** (attempt - 1))
                continue
            raise RuntimeError(f"Network error during download for {url}: {e}") from e


def normalize_version_from_tag(tag: str) -> str:
    return tag[1:] if tag.startswith("v") else tag


def build_manifest(
    repo: str,
    tag: str,
    channel: str,
    token: str,
    rules_path: str,
    retries: int,
) -> Dict[str, Any]:
    owner, name = repo.split("/", 1)
    release_url = f"{GITHUB_API}/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(name)}/releases/tags/{urllib.parse.quote(tag)}"
    release = http_json(release_url, github_headers(token), retries)
    rules = load_rules(rules_path)

    selected_assets: Dict[str, Dict[str, Any]] = {}
    seen_source_names: Dict[str, str] = {}
    skipped_unmapped: List[str] = []
    for asset in release.get("assets", []):
        asset_name = asset.get("name", "")
        if not asset_name or asset_name in SKIP_ASSET_NAMES:
            continue
        classification = classify_asset(asset_name, rules)
        if not classification:
            skipped_unmapped.append(asset_name)
            continue

        download_url = asset.get("browser_download_url")
        if not download_url:
            continue

        platform_key = classification["platform"]
        digest = sha256_from_url(download_url, github_headers(token), retries)
        if platform_key in selected_assets:
            raise RuntimeError(
                f"Multiple assets map to the same platform '{platform_key}': "
                f"{seen_source_names[platform_key]} and {asset_name}. "
                "Adjust naming or scripts/updater/platform_rules.json."
            )

        size = int(asset.get("size", 0))
        if size <= 0:
            raise RuntimeError(f"Invalid asset size for {asset_name}: {size}")

        selected_assets[platform_key] = {
            "name": asset_name,
            "os": classification["os"],
            "arch": classification["arch"],
            "installer": classification["installer"],
            "size": size,
            "sha256": digest,
            "download_url": download_url,
            "content_type": asset.get("content_type"),
        }
        seen_source_names[platform_key] = asset_name

    if not selected_assets:
        raise RuntimeError(
            "No installer assets matched platform rules. "
            f"Unmapped assets: {', '.join(skipped_unmapped) if skipped_unmapped else '(none)'}"
        )

    manifest: Dict[str, Any] = {
        "schema_version": 1,
        "repo": repo,
        "channel": channel,
        "tag": release.get("tag_name", tag),
        "version": normalize_version_from_tag(release.get("tag_name", tag)),
        "published_at": release.get("published_at"),
        "release_url": release.get("html_url"),
        "generated_at": utc_now_iso(),
        "assets": {k: selected_assets[k] for k in sorted(selected_assets.keys())},
    }
    return manifest


def main() -> int:
    args = parse_args()
    token = args.token or os_env("GITHUB_TOKEN", default="")
    manifest = build_manifest(
        repo=args.repo,
        tag=args.tag,
        channel=args.channel,
        token=token,
        rules_path=args.rules,
        retries=args.retries,
    )
    output_path = pathlib.Path(args.output)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {output_path} with {len(manifest['assets'])} platform assets")
    return 0


def os_env(name: str, default: str = "") -> str:
    import os

    return os.environ.get(name, default)


if __name__ == "__main__":
    raise SystemExit(main())
