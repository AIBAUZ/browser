[CmdletBinding()]
param(
  [string]$Repo = "AIBAUZ/browser",
  [string]$Tag = "",
  [ValidateSet("stable", "beta")]
  [string]$Channel = "stable",
  [string]$Title = "",
  [string]$Notes = "First stable release",
  [string]$NotesFile = "",
  [string]$MacAsset = "",
  [string]$WinAsset = "",
  [string]$PrivateKeyFile = "",
  [string]$PublicKeyPath = "release/keys/updater-signing-public.pem",
  [switch]$NoPushConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log([string]$Message) {
  Write-Host "[release] $Message"
}

function Die([string]$Message) {
  throw "[release][error] $Message"
}

function Require-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Die "Missing required command: $Name"
  }
}

function Read-AppVersion([string]$RootPath) {
  $versionPath = Join-Path $RootPath "version.txt"
  if (-not (Test-Path -LiteralPath $versionPath)) {
    Die "Missing version file: $versionPath"
  }
  $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
  if ([string]::IsNullOrWhiteSpace($version)) {
    Die "version.txt is empty"
  }
  return $version
}

function Ensure-TagMatchesAppVersion([string]$AppVersion) {
  $expectedTag = "v$AppVersion"
  if ([string]::IsNullOrWhiteSpace($script:Tag)) {
    $script:Tag = $expectedTag
    Log "Using tag from version.txt: $script:Tag"
    return
  }
  if ($script:Tag -ne $expectedTag) {
    Die "Tag/version mismatch: tag=$script:Tag but version.txt=$AppVersion (expected $expectedTag)"
  }
}

function Get-OpenSslExecutable {
  if (Get-Variable -Name OpenSslExecutable -Scope Script -ErrorAction SilentlyContinue) {
    return $script:OpenSslExecutable
  }

  $cmd = Get-Command "openssl" -ErrorAction SilentlyContinue
  if ($cmd) {
    $script:OpenSslExecutable = $cmd.Source
    return $script:OpenSslExecutable
  }

  $candidates = @(
    (Join-Path $env:ProgramFiles "Git\usr\bin\openssl.exe"),
    (Join-Path $env:ProgramFiles "Git\mingw64\bin\openssl.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\usr\bin\openssl.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\mingw64\bin\openssl.exe"),
    (Join-Path $env:ProgramFiles "OpenSSL-Win64\bin\openssl.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "OpenSSL-Win32\bin\openssl.exe"),
    "C:\msys64\usr\bin\openssl.exe"
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      $script:OpenSslExecutable = $candidate
      Log "Using OpenSSL: $candidate"
      return $script:OpenSslExecutable
    }
  }

  Die "Missing required command: openssl (not in PATH and not found in common install locations)"
}

function Invoke-GhCapture([string[]]$Argv) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & gh @Argv 2>&1
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $prevEap
  }

  if ($code -ne 0) {
    $text = if ($output) { ($output | Out-String).Trim() } else { "(no output)" }
    Die "gh $($Argv -join ' ') failed: $text"
  }
  return ($output | Out-String).Trim()
}

function Test-RemoteWorkflowExists {
  & gh api "repos/$Repo/contents/.github/workflows/release-update-manifest.yml" *> $null
  return ($LASTEXITCODE -eq 0)
}

function Ensure-RemoteWorkflowPresent {
  if (-not (Test-RemoteWorkflowExists)) {
    Die "Workflow '.github/workflows/release-update-manifest.yml' is not in $Repo yet. Push updater files first, then rerun."
  }
}

function Repo-DefaultBranch {
  $branch = (Invoke-GhCapture @("api", "repos/$Repo", "--jq", ".default_branch")).Trim()
  if ([string]::IsNullOrWhiteSpace($branch)) {
    Die "Could not resolve default branch for $Repo"
  }
  return $branch
}

function Build-UpdaterFileList {
  $files = @(
    ".github/workflows/release-update-manifest.yml",
    "docs/updater/README.md",
    "docs/updater/IMPLEMENTATION_PLAN.md",
    "docs/updater/update-manifest.schema.json",
    "docs/updater/reference_client/updater_client.py",
    "scripts/updater/build_update_manifest.py",
    "scripts/updater/sign_manifest.py",
    "scripts/updater/verify_manifest_signature.py",
    "scripts/updater/platform_rules.json",
    "scripts/updater/generate_signing_keypair.sh",
    "scripts/release/publish_release.sh",
    "scripts/release/publish_release.ps1",
    "release/Readme.md",
    "README.md",
    "version.txt"
  )

  if (Test-Path -LiteralPath $PublicKeyPath) {
    $files += $PublicKeyPath
  }

  $existing = @()
  foreach ($f in $files) {
    if (Test-Path -LiteralPath $f) {
      $existing += $f
    }
  }

  if ($existing.Count -eq 0) {
    Die "No updater files found to sync"
  }

  return $existing
}

function Upsert-FileViaGhApi([string]$Path, [string]$Branch) {
  $sha = ""
  try {
    $shaOut = Invoke-GhCapture @("api", "repos/$Repo/contents/${Path}?ref=${Branch}", "--jq", ".sha")
    if ($shaOut) {
      $sha = ($shaOut | Out-String).Trim()
    }
  }
  catch {
    $msg = $_.Exception.Message
    if ($msg -notmatch "404|Not Found") {
      throw
    }
  }

  $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
  $contentB64 = [Convert]::ToBase64String($bytes)

  $payload = @{
    message = "chore(updater): sync $Path"
    branch  = $Branch
    content = $contentB64
  }
  if ($sha) {
    $payload.sha = $sha
  }

  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    $json = ($payload | ConvertTo-Json -Depth 5 -Compress)
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    $null = Invoke-GhCapture @("api", "--method", "PUT", "repos/$Repo/contents/$Path", "--input", $tmp)
  }
  finally {
    if (Test-Path -LiteralPath $tmp) {
      Remove-Item -LiteralPath $tmp -Force
    }
  }
}

function Sync-UpdaterFilesViaGhApi {
  $branch = Repo-DefaultBranch
  if (-not $branch) {
    Die "Could not resolve default branch for $Repo"
  }

  Log "Syncing updater files via GitHub API to $Repo@$branch"
  $files = Build-UpdaterFileList
  foreach ($f in $files) {
    Upsert-FileViaGhApi -Path $f -Branch $branch
  }
  Log "Synced $($files.Count) updater files to $Repo@$branch"
}

function Normalize-GithubRepoFromRemote([string]$RemoteUrl) {
  if (-not $RemoteUrl) {
    return ""
  }

  if ($RemoteUrl -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$") {
    return "$($Matches.owner)/$($Matches.repo)".ToLowerInvariant()
  }

  return ""
}

function Should-SyncUpdaterFilesViaGhApi([string]$OriginUrl) {
  $originRepo = Normalize-GithubRepoFromRemote -RemoteUrl $OriginUrl
  if (-not $originRepo) {
    return $true
  }

  return ($originRepo -ne $Repo.ToLowerInvariant())
}

function Ensure-Auth {
  & gh auth status *> $null
  if ($LASTEXITCODE -ne 0) {
    Die "GitHub CLI is not authenticated. Run: gh auth login"
  }

  $null = Invoke-GhCapture @("repo", "view", $Repo, "--json", "nameWithOwner")
}

function Ensure-Secret {
  $secretsOut = Invoke-GhCapture @("secret", "list", "--repo", $Repo, "--json", "name", "--jq", ".[].name")
  $secretNames = @($secretsOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($secretNames -contains "UPDATER_SIGNING_PRIVATE_KEY_PEM") {
    Log "Secret UPDATER_SIGNING_PRIVATE_KEY_PEM already exists"
    return
  }

  $keyFile = $PrivateKeyFile
  $tmpDir = ""
  $generated = $false

  if (-not $keyFile) {
    $openssl = Get-OpenSslExecutable
    $generated = $true
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("aiba-updater-key-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $keyFile = Join-Path $tmpDir "updater-signing-private.pem"
    $pubFile = Join-Path $tmpDir "updater-signing-public.pem"

    & $openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out $keyFile -quiet *> $null
    if ($LASTEXITCODE -ne 0) { Die "openssl genpkey failed" }
    & $openssl pkey -in $keyFile -pubout -out $pubFile *> $null
    if ($LASTEXITCODE -ne 0) { Die "openssl pkey -pubout failed" }

    $publicDir = Split-Path -Parent $PublicKeyPath
    if ($publicDir) {
      New-Item -ItemType Directory -Path $publicDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $pubFile -Destination $PublicKeyPath -Force
    Log "Generated new updater keypair. Public key saved: $PublicKeyPath"
  }
  else {
    if (-not (Test-Path -LiteralPath $keyFile)) {
      Die "Private key file not found: $keyFile"
    }
    if (-not (Test-Path -LiteralPath $PublicKeyPath)) {
      $openssl = Get-OpenSslExecutable
      $publicDir = Split-Path -Parent $PublicKeyPath
      if ($publicDir) {
        New-Item -ItemType Directory -Path $publicDir -Force | Out-Null
      }
      & $openssl pkey -in $keyFile -pubout -out $PublicKeyPath *> $null
      if ($LASTEXITCODE -ne 0) { Die "Failed to derive public key from private key" }
      Log "Derived public key from private key: $PublicKeyPath"
    }
  }

  try {
    Get-Content -LiteralPath $keyFile -Raw | gh secret set UPDATER_SIGNING_PRIVATE_KEY_PEM --repo $Repo
    if ($LASTEXITCODE -ne 0) {
      Die "Failed to set GitHub secret UPDATER_SIGNING_PRIVATE_KEY_PEM"
    }
    Log "Set GitHub secret: UPDATER_SIGNING_PRIVATE_KEY_PEM"
  }
  finally {
    if ($generated -and $tmpDir -and (Test-Path -LiteralPath $tmpDir)) {
      Remove-Item -LiteralPath $tmpDir -Force -Recurse
    }
  }
}

function Push-UpdaterConfig {
  if ($NoPushConfig) {
    Log "Skipping updater config push (--NoPushConfig)"
    return
  }

  $originUrl = (& git remote get-url origin 2>$null | Out-String).Trim()
  $hasOrigin = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($originUrl))

  if (-not $hasOrigin) {
    Log "Git remote 'origin' is missing. Using GitHub API sync instead of git push."
    Sync-UpdaterFilesViaGhApi
    return
  }

  $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $branch -eq "HEAD") {
    Die "Detached HEAD. Checkout a branch before running script."
  }

  $files = Build-UpdaterFileList
  & git add -- @files
  if ($LASTEXITCODE -ne 0) { Die "git add failed" }

  & git diff --cached --quiet
  if ($LASTEXITCODE -ne 0) {
    & git commit -m "chore(updater): add release automation and docs"
    if ($LASTEXITCODE -ne 0) { Die "git commit failed" }
    Log "Committed updater config changes"
  }
  else {
    Log "No updater config changes to commit"
  }

  & git push origin $branch
  if ($LASTEXITCODE -ne 0) { Die "git push failed" }
  Log "Pushed branch: $branch"

  if (Should-SyncUpdaterFilesViaGhApi -OriginUrl $originUrl) {
    Log "Origin remote does not point to GitHub repo $Repo. Syncing updater files via GitHub API."
    Sync-UpdaterFilesViaGhApi
  }
}

function Find-InstallerAsset([string]$Kind) {
  $searchRoots = New-Object System.Collections.Generic.List[string]
  $searchRoots.Add((Resolve-Path -LiteralPath ".").Path) | Out-Null

  # On this repo layout installers are often one level above cef-project.
  $parent = Resolve-Path -LiteralPath (Join-Path "." "..") -ErrorAction SilentlyContinue
  if ($parent) {
    $searchRoots.Add($parent.Path) | Out-Null
  }

  $pattern = if ($Kind -eq "mac") {
    "(?i)^AIBABrowser.*\.(pkg|dmg)$"
  }
  else {
    "(?i)^AIBABrowser.*\.(exe|msi)$"
  }

  foreach ($root in ($searchRoots | Select-Object -Unique)) {
    $found = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match $pattern } |
      Sort-Object FullName |
      Select-Object -First 1 -ExpandProperty FullName

    if ($found) {
      return $found
    }
  }

  return ""
}

function Ensure-Assets {
  if (-not $script:MacAsset) {
    $script:MacAsset = Find-InstallerAsset -Kind "mac"
  }
  if (-not $script:WinAsset) {
    $script:WinAsset = Find-InstallerAsset -Kind "win"
  }

  $assets = New-Object System.Collections.Generic.List[string]

  if ($script:MacAsset) {
    if (Test-Path -LiteralPath $script:MacAsset) {
      $assets.Add($script:MacAsset) | Out-Null
      Log "Using macOS asset: $script:MacAsset"
    }
    else {
      Log "Warning: macOS asset path does not exist, skipping: $script:MacAsset"
    }
  }
  else {
    Log "Warning: macOS installer not found"
  }

  if ($script:WinAsset) {
    if (Test-Path -LiteralPath $script:WinAsset) {
      $assets.Add($script:WinAsset) | Out-Null
      Log "Using Windows asset: $script:WinAsset"
    }
    else {
      Log "Warning: Windows asset path does not exist, skipping: $script:WinAsset"
    }
  }
  else {
    Log "Warning: Windows installer not found"
  }

  if ($assets.Count -eq 0) {
    Die "No valid installer assets found. Provide at least one existing installer file."
  }

  return $assets
}

function Create-OrUpdateRelease([System.Collections.Generic.List[string]]$Assets) {
  if (-not $Title) {
    $script:Title = "AIBA Browser $Tag"
  }

  $releaseExists = $false
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & gh release view $Tag --repo $Repo *> $null
    $releaseExists = ($LASTEXITCODE -eq 0)
  }
  finally {
    $ErrorActionPreference = $prevEap
  }

  if ($releaseExists) {
    Log "Release $Tag exists. Uploading/replacing assets"
    & gh release upload $Tag @Assets --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) { Die "Failed to upload release assets" }
    return
  }

  $args = New-Object System.Collections.Generic.List[string]
  $args.Add("release")
  $args.Add("create")
  $args.Add($Tag)
  foreach ($a in $Assets) { $args.Add($a) }
  $args.Add("--repo"); $args.Add($Repo)
  $args.Add("--title"); $args.Add($Title)

  if ($NotesFile) {
    if (-not (Test-Path -LiteralPath $NotesFile)) {
      Die "Notes file not found: $NotesFile"
    }
    $args.Add("--notes-file"); $args.Add($NotesFile)
  }
  else {
    $args.Add("--notes"); $args.Add($Notes)
  }

  if ($Channel -eq "beta") {
    $args.Add("--prerelease")
  }
  else {
    $args.Add("--latest")
  }

  Log "Creating release $Tag"
  & gh @args
  if ($LASTEXITCODE -ne 0) { Die "Failed to create release $Tag" }
}

function Trigger-AndWaitManifestWorkflow {
  $startUtc = (Get-Date).ToUniversalTime()
  Log "Triggering release-update-manifest.yml for tag=$Tag channel=$Channel"
  & gh workflow run release-update-manifest.yml --repo $Repo -f "tag=$Tag" -f "channel=$Channel"
  if ($LASTEXITCODE -ne 0) { Die "Failed to trigger release-update-manifest.yml" }

  $runId = ""
  for ($i = 0; $i -lt 24; $i++) {
    $runsRaw = & gh run list `
      --repo $Repo `
      --workflow release-update-manifest.yml `
      --limit 20 `
      --json databaseId,createdAt,event,status 2>$null

    if ($LASTEXITCODE -eq 0 -and $runsRaw) {
      $runsJson = ($runsRaw | Out-String).Trim()
      try {
        $runs = @($runsJson | ConvertFrom-Json)
        $candidate = @($runs | Where-Object {
          $_.event -eq "workflow_dispatch" -and ([DateTime]::Parse($_.createdAt).ToUniversalTime() -ge $startUtc.AddSeconds(-5))
        } | Select-Object -First 1)

        # Fallback for clock skew / fast-completing runs: pick most recent dispatch.
        if ($candidate.Count -eq 0) {
          $candidate = @($runs | Where-Object { $_.event -eq "workflow_dispatch" } | Select-Object -First 1)
        }

        if ($candidate.Count -gt 0) {
          $runId = $candidate[0].databaseId.ToString().Trim()
          if ($runId) {
            break
          }
        }
      }
      catch {
        # Ignore transient non-JSON output and retry.
      }
    }
    Start-Sleep -Seconds 5
  }

  if (-not $runId) {
    Die "Could not find triggered workflow run for release-update-manifest.yml"
  }

  Log "Watching workflow run id=$runId"
  & gh run watch $runId --repo $Repo --exit-status
  if ($LASTEXITCODE -ne 0) { Die "Workflow run failed: $runId" }
}

function Verify-ReleaseMetadataAssets {
  $names = Invoke-GhCapture @("release", "view", $Tag, "--repo", $Repo, "--json", "assets", "--jq", ".assets[].name")
  $set = @($names -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($set -notcontains "update-manifest.json") {
    Die "Release missing update-manifest.json"
  }
  if ($set -notcontains "update-manifest.sig") {
    Die "Release missing update-manifest.sig"
  }
  Log "Release contains update-manifest.json and update-manifest.sig"
}

function Main {
  Require-Cmd "gh"
  Require-Cmd "git"
  Require-Cmd "python"

  $root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
  Set-Location -LiteralPath $root
  $appVersion = Read-AppVersion -RootPath $root
  Ensure-TagMatchesAppVersion -AppVersion $appVersion

  Ensure-Auth
  Ensure-Secret
  Push-UpdaterConfig
  Ensure-RemoteWorkflowPresent
  $assets = Ensure-Assets
  Create-OrUpdateRelease -Assets $assets
  Trigger-AndWaitManifestWorkflow
  Verify-ReleaseMetadataAssets

  $url = Invoke-GhCapture @("release", "view", $Tag, "--repo", $Repo, "--json", "url", "--jq", ".url")
  Log "SUCCESS: $url"
}

Main
