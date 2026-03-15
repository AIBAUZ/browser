# Updater Implementation Plan

## Scope

This repository is the updater distribution source, not the browser source code.
Implementation therefore has two tracks:

1. **In this repo (implemented):**
   - Release-side metadata generation/signing
   - Automated publishing in GitHub Actions
   - Updater contract/specification
2. **In browser source repo (next):**
   - Native updater client integration
   - UI prompts, download progress, installer bridge

## Step-by-step design

1. **Release publish**
   - Upload installer artifacts to GitHub Release (`vX.Y.Z`).
   - Workflow computes SHA-256 per installer, generates `update-manifest.json`.
   - Workflow signs manifest with private key (`UPDATER_SIGNING_PRIVATE_KEY_PEM`).
   - Workflow uploads `update-manifest.json` and `update-manifest.sig` to the same release.

2. **Browser update check**
   - On startup delay (30-60 sec), then every 24h with jitter.
   - Call `GET /repos/AIBAUZ/browser/releases/latest` with `If-None-Match`.
   - If `304`: skip.
   - If `200`: compare semver with current app version.
   - If newer: download manifest + signature from release assets.

3. **Verification pipeline**
   - Verify `update-manifest.sig` using pinned updater public key.
   - Select platform asset (`windows-x64`, `macos-arm64`, etc).
   - Download installer to cache location.
   - Verify SHA-256 against manifest.
   - Verify OS package signature:
     - Windows: Authenticode publisher check.
     - macOS: signature + notarization + Team ID check.

4. **Install strategy**
   - Browser process does not self-overwrite.
   - Spawn updater helper process.
   - Helper waits for browser exit, launches installer.
   - Optional relaunch after successful install.

## GitHub API usage

- Latest stable:
  - `GET https://api.github.com/repos/AIBAUZ/browser/releases/latest`
- Header set:
  - `Accept: application/vnd.github+json`
  - `X-GitHub-Api-Version: 2022-11-28`
  - `User-Agent: AIBABrowser-Updater/<version>`
  - `If-None-Match: <etag>`
- Rate-limit resilience:
  - Store and reuse ETag
  - Exponential backoff on 5xx

## Security requirements

1. Pinned updater public key in browser binary.
2. Detached signature verification for manifest.
3. SHA-256 verification for downloaded installer.
4. OS-level signature validation for installer package.
5. HTTPS-only + host allowlist.
6. Downgrade prevention (`latest <= current` is ignored).

## Implemented files in this repository

- `scripts/updater/build_update_manifest.py`
- `scripts/updater/sign_manifest.py`
- `scripts/updater/verify_manifest_signature.py`
- `scripts/updater/platform_rules.json`
- `scripts/updater/generate_signing_keypair.sh`
- `.github/workflows/release-update-manifest.yml`
- `docs/updater/update-manifest.schema.json`
- `docs/updater/reference_client/updater_client.py`

