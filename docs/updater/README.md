# AIBA Browser Update System (GitHub Releases)

This repository is treated as the distribution source for browser updates.
The updater contract is:

1. Browser checks GitHub Releases for a newer version.
2. Browser downloads `update-manifest.json` from the release.
3. Browser verifies `update-manifest.sig`.
4. Browser downloads the platform installer defined in the manifest.
5. Browser verifies SHA-256 and OS-level package signature before install.

## Release Contract

Each stable release (`vX.Y.Z`) must include:

- Installer assets (`.exe`/`.msi`, `.pkg`, optional Linux assets)
- `update-manifest.json`
- `update-manifest.sig` (detached signature of the manifest)

Manifest/signature can be generated automatically by workflow:

- `.github/workflows/release-update-manifest.yml`

## Scripts

- `scripts/updater/build_update_manifest.py`
  - Reads release assets from GitHub API
  - Calculates SHA-256 for installers
  - Emits normalized manifest
- `scripts/updater/sign_manifest.py`
  - Creates detached signature with OpenSSL private key
- `scripts/updater/verify_manifest_signature.py`
  - Verifies manifest signature with OpenSSL public key
- `scripts/updater/generate_signing_keypair.sh`
  - One-time helper to create RSA signing key pair

## Browser Integration

Reference C++ code for browser-side integration:

- `docs/updater/reference_client/updater_example.cpp`
- `docs/updater/SELF_UPDATE_IMPLEMENTATION_V1.md` (what was implemented in this repo)

In production, move that module into the private browser source repository and:

1. Embed the updater public key (pin).
2. Schedule update checks (startup + periodic).
3. Verify manifest signature + SHA-256 before install.
4. Verify installer code-signing/notarization at OS level.
