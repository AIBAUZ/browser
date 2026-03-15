# AIBA Browser Release + Auto Update (Windows + macOS)

This repository can serve both platforms from the same GitHub Release.

## One release, two platforms

For each version (example: `v1.2.3`) publish **one** GitHub release that includes:

- Windows installer (`.exe` or `.msi`)
- macOS installer (`.pkg` or `.dmg`)
- `update-manifest.json`
- `update-manifest.sig`

The browser updater checks the same release and picks the asset for the current OS.

## Required asset naming

Use clear platform names so manifest generation can classify assets:

- `AIBABrowser-windows-x64.exe`
- `AIBABrowser-macos-arm64.pkg`
- `AIBABrowser-macos-x64.pkg` (or one universal package)

Optional universal mac package:

- `AIBABrowser-macos-universal.pkg`

## Update flow (both OS)

1. Browser calls GitHub API:
   - `GET /repos/AIBAUZ/browser/releases/latest`
2. If newer version exists:
   - download `update-manifest.json` and `update-manifest.sig`
   - verify manifest signature using pinned public key
3. Select platform key:
   - Windows Intel/AMD: `windows-x64`
   - macOS Apple Silicon: `macos-arm64`
   - macOS Intel: `macos-x64`
4. Download platform installer from manifest URL.
5. Verify SHA-256 from manifest.
6. Verify OS package signing:
   - Windows Authenticode publisher
   - macOS signature/notarization/Team ID
7. Prompt user to install (or auto-install based on policy).

## Publish commands (GitHub CLI)

## One-command publish script

Use this script to do the full flow automatically:

```bash
./scripts/release/publish_release.sh \
  --tag v1.0.0 \
  --mac ./AIBABrowserInstaller.pkg \
  --win ./dist/AIBABrowser-windows-x64.exe \
  --notes "First stable release"
```

It will:

1. ensure updater signing secret exists
2. push updater workflow/config files
3. create (or update) the GitHub release with both assets
4. trigger manifest/signature workflow
5. wait and verify `update-manifest.json` + `update-manifest.sig` were uploaded

## Windows one-command script (.ps1)

On Windows machine (where `.exe` is built), run:

```powershell
.\scripts\release\publish_release.ps1 `
  -Tag v1.0.0 `
  -WinAsset "C:\build\AIBABrowser-windows-x64.exe" `
  -Notes "First stable release"
```

If you also have macOS installer locally on that machine, add:

```powershell
-MacAsset "C:\build\AIBABrowserInstaller.pkg"
```

The PowerShell script performs the same steps as bash script, including:

1. ensuring updater signing secret exists
2. syncing updater workflow/config to GitHub
3. creating/updating release assets
4. triggering manifest/signature workflow
5. waiting and verifying release metadata assets

Manual command alternative:

```bash
gh release create v1.2.3 \
  ./dist/AIBABrowser-windows-x64.exe \
  ./dist/AIBABrowser-macos-arm64.pkg \
  ./dist/AIBABrowser-macos-x64.pkg \
  --title "AIBA Browser v1.2.3" \
  --notes "Windows + macOS release"
```

If release already exists:

```bash
gh release upload v1.2.3 \
  ./dist/AIBABrowser-windows-x64.exe \
  ./dist/AIBABrowser-macos-arm64.pkg \
  ./dist/AIBABrowser-macos-x64.pkg \
  --clobber
```

## Auto-generate update metadata in this repo

This repo already contains automation:

- Workflow: `.github/workflows/release-update-manifest.yml`
- Scripts: `scripts/updater/*`

When a release is published, workflow can:

1. generate `update-manifest.json` with both Windows/macOS entries
2. sign it as `update-manifest.sig`
3. upload both files back to the same release

## One-time setup (required)

Add GitHub Actions secret:

- `UPDATER_SIGNING_PRIVATE_KEY_PEM` = private PEM key content

Public key must be embedded/pinned in the browser updater code.
