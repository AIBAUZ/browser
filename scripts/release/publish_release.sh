#!/usr/bin/env bash
set -euo pipefail

REPO="AIBAUZ/browser"
TAG="v1.0.0"
CHANNEL="stable"
TITLE=""
NOTES="First stable release"
NOTES_FILE=""
MAC_ASSET=""
WIN_ASSET=""
PRIVATE_KEY_FILE=""
PUBLIC_KEY_PATH="release/keys/updater-signing-public.pem"
PUSH_CONFIG="true"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSETS_TO_UPLOAD=()

log() {
  printf '[release] %s\n' "$*"
}

die() {
  printf '[release][error] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release/publish_release.sh [options]

Options:
  --repo OWNER/REPO               GitHub repo (default: AIBAUZ/browser)
  --tag vX.Y.Z                    Release tag (default: v1.0.0)
  --channel stable|beta           Update channel (default: stable)
  --title "Release title"         Release title (default: AIBA Browser <tag>)
  --notes "Release notes"         Release notes text (default: "First stable release")
  --notes-file PATH               Release notes file path
  --mac PATH                      macOS installer asset (.pkg/.dmg). Auto-discovered if omitted.
  --win PATH                      Windows installer asset (.exe/.msi). Auto-discovered if omitted.
  --private-key-file PATH         Existing updater signing private key PEM file.
  --public-key-path PATH          Public key output path (default: release/keys/updater-signing-public.pem)
  --no-push-config                Do not auto-commit/push updater config files before release
  -h, --help                      Show help

What this script does:
  1) Ensures UPDATER_SIGNING_PRIVATE_KEY_PEM exists in GitHub secrets.
  2) Commits and pushes updater workflow/docs/scripts (unless --no-push-config).
     If local git remote 'origin' is missing, files are synced via GitHub API.
  3) Creates or updates a GitHub Release with macOS + Windows assets.
  4) Triggers release-update-manifest.yml workflow.
  5) Waits for workflow completion.
  6) Verifies release now contains update-manifest.json and update-manifest.sig.

Notes:
  - At least one valid installer is required.
  - If one platform installer is missing, release still proceeds with available assets.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

repo_default_branch() {
  gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name'
}

build_updater_file_list() {
  local files=(
    ".github/workflows/release-update-manifest.yml"
    "docs/updater/README.md"
    "docs/updater/IMPLEMENTATION_PLAN.md"
    "docs/updater/update-manifest.schema.json"
    "docs/updater/reference_client/updater_client.py"
    "scripts/updater/build_update_manifest.py"
    "scripts/updater/sign_manifest.py"
    "scripts/updater/verify_manifest_signature.py"
    "scripts/updater/platform_rules.json"
    "scripts/updater/generate_signing_keypair.sh"
    "scripts/release/publish_release.sh"
    "release/Readme.md"
    "README.md"
  )
  if [[ -f "$PUBLIC_KEY_PATH" ]]; then
    files+=("$PUBLIC_KEY_PATH")
  fi

  local existing=()
  local f
  for f in "${files[@]}"; do
    [[ -e "$f" ]] && existing+=("$f")
  done

  if [[ "${#existing[@]}" -eq 0 ]]; then
    die "No updater files found to push"
  fi

  printf '%s\n' "${existing[@]}"
}

upsert_file_via_gh_api() {
  local path="$1"
  local branch="$2"
  local sha=""
  sha="$(gh api "repos/$REPO/contents/$path?ref=$branch" --jq '.sha' 2>/dev/null || true)"

  local tmp_json
  tmp_json="$(mktemp)"
  python3 - "$path" "$branch" "$sha" > "$tmp_json" <<'PY'
import base64
import json
import pathlib
import sys

path = sys.argv[1]
branch = sys.argv[2]
sha = sys.argv[3]
raw = pathlib.Path(path).read_bytes()
payload = {
    "message": f"chore(updater): sync {path}",
    "branch": branch,
    "content": base64.b64encode(raw).decode("ascii"),
}
if sha:
    payload["sha"] = sha
print(json.dumps(payload))
PY

  gh api --method PUT "repos/$REPO/contents/$path" --input "$tmp_json" >/dev/null
  rm -f "$tmp_json"
}

sync_updater_files_via_gh_api() {
  local branch
  branch="$(repo_default_branch)"
  [[ -n "$branch" ]] || die "Could not resolve default branch for $REPO"
  log "Syncing updater files via GitHub API to $REPO@$branch"

  local count=0
  local f
  while IFS= read -r f; do
    upsert_file_via_gh_api "$f" "$branch"
    count=$((count + 1))
  done < <(build_updater_file_list)

  log "Synced $count updater files to $REPO@$branch"
}

normalize_github_repo_from_remote() {
  local url="$1"
  if [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$ ]]; then
    printf '%s/%s' "${BASH_REMATCH[1],,}" "${BASH_REMATCH[2],,}"
  fi
}

should_sync_via_gh_api_after_push() {
  local origin_url="$1"
  local target_repo="${REPO,,}"
  local origin_repo=""
  origin_repo="$(normalize_github_repo_from_remote "$origin_url")"
  [[ -z "$origin_repo" || "$origin_repo" != "$target_repo" ]]
}

discover_asset() {
  local pattern="$1"
  local first=""
  # shellcheck disable=SC2016
  first="$(find . -maxdepth 3 -type f \( $pattern \) | sort | head -n 1 || true)"
  printf '%s' "$first"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO="$2"; shift 2 ;;
      --tag) TAG="$2"; shift 2 ;;
      --channel) CHANNEL="$2"; shift 2 ;;
      --title) TITLE="$2"; shift 2 ;;
      --notes) NOTES="$2"; shift 2 ;;
      --notes-file) NOTES_FILE="$2"; shift 2 ;;
      --mac) MAC_ASSET="$2"; shift 2 ;;
      --win) WIN_ASSET="$2"; shift 2 ;;
      --private-key-file) PRIVATE_KEY_FILE="$2"; shift 2 ;;
      --public-key-path) PUBLIC_KEY_PATH="$2"; shift 2 ;;
      --no-push-config) PUSH_CONFIG="false"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

ensure_auth() {
  gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"
  gh repo view "$REPO" --json nameWithOwner >/dev/null 2>&1 || die "Cannot access repo: $REPO"
}

remote_workflow_exists() {
  gh api "repos/$REPO/contents/.github/workflows/release-update-manifest.yml" >/dev/null 2>&1
}

ensure_remote_workflow_present() {
  if ! remote_workflow_exists; then
    die "Workflow '.github/workflows/release-update-manifest.yml' is not in $REPO yet. Push updater files first, then rerun."
  fi
}

ensure_secret() {
  if gh secret list --repo "$REPO" | awk '{print $1}' | grep -qx 'UPDATER_SIGNING_PRIVATE_KEY_PEM'; then
    log "Secret UPDATER_SIGNING_PRIVATE_KEY_PEM already exists"
    return 0
  fi

  local tmp_dir=""
  local key_file="$PRIVATE_KEY_FILE"
  local generated="false"

  if [[ -z "$key_file" ]]; then
    generated="true"
    tmp_dir="$(mktemp -d)"
    key_file="$tmp_dir/updater-signing-private.pem"
    local pub_file="$tmp_dir/updater-signing-public.pem"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$key_file" >/dev/null 2>&1
    openssl pkey -in "$key_file" -pubout -out "$pub_file" >/dev/null 2>&1

    mkdir -p "$(dirname "$PUBLIC_KEY_PATH")"
    cp "$pub_file" "$PUBLIC_KEY_PATH"
    chmod 644 "$PUBLIC_KEY_PATH"
    log "Generated new updater keypair. Public key saved: $PUBLIC_KEY_PATH"
  else
    [[ -f "$key_file" ]] || die "Private key file not found: $key_file"
    if [[ ! -f "$PUBLIC_KEY_PATH" ]]; then
      mkdir -p "$(dirname "$PUBLIC_KEY_PATH")"
      openssl pkey -in "$key_file" -pubout -out "$PUBLIC_KEY_PATH" >/dev/null 2>&1
      chmod 644 "$PUBLIC_KEY_PATH"
      log "Derived public key from private key: $PUBLIC_KEY_PATH"
    fi
  fi

  gh secret set UPDATER_SIGNING_PRIVATE_KEY_PEM --repo "$REPO" < "$key_file"
  log "Set GitHub secret: UPDATER_SIGNING_PRIVATE_KEY_PEM"

  if [[ "$generated" == "true" ]]; then
    rm -rf "$tmp_dir"
  fi
}

push_updater_config() {
  [[ "$PUSH_CONFIG" == "true" ]] || { log "Skipping updater config push (--no-push-config)"; return 0; }

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$branch" != "HEAD" ]] || die "Detached HEAD. Checkout a branch before running script."
  local origin_url=""
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "$origin_url" ]]; then
    log "Git remote 'origin' is missing. Using GitHub API sync instead of git push."
    sync_updater_files_via_gh_api
    return 0
  fi
  local existing=()
  local f
  while IFS= read -r f; do
    existing+=("$f")
  done < <(build_updater_file_list)

  git add -- "${existing[@]}"
  if ! git diff --cached --quiet; then
    git commit -m "chore(updater): add release automation and docs"
    log "Committed updater config changes"
  else
    log "No updater config changes to commit"
  fi

  git push origin "$branch"
  log "Pushed branch: $branch"

  if should_sync_via_gh_api_after_push "$origin_url"; then
    log "Origin remote does not point to GitHub repo $REPO. Syncing updater files via GitHub API."
    sync_updater_files_via_gh_api
  fi
}

ensure_assets() {
  if [[ -z "$MAC_ASSET" ]]; then
    MAC_ASSET="$(discover_asset '-name "*.pkg" -o -name "*.dmg"')"
  fi
  if [[ -z "$WIN_ASSET" ]]; then
    WIN_ASSET="$(discover_asset '-name "*.exe" -o -name "*.msi"')"
  fi

  ASSETS_TO_UPLOAD=()

  if [[ -n "$MAC_ASSET" ]]; then
    if [[ -f "$MAC_ASSET" ]]; then
      ASSETS_TO_UPLOAD+=("$MAC_ASSET")
      log "Using macOS asset: $MAC_ASSET"
    else
      log "Warning: macOS asset path does not exist, skipping: $MAC_ASSET"
    fi
  else
    log "Warning: macOS installer not found"
  fi

  if [[ -n "$WIN_ASSET" ]]; then
    if [[ -f "$WIN_ASSET" ]]; then
      ASSETS_TO_UPLOAD+=("$WIN_ASSET")
      log "Using Windows asset: $WIN_ASSET"
    else
      log "Warning: Windows asset path does not exist, skipping: $WIN_ASSET"
    fi
  else
    log "Warning: Windows installer not found"
  fi

  [[ "${#ASSETS_TO_UPLOAD[@]}" -gt 0 ]] || die "No valid installer assets found. Provide at least one existing installer file."
}

create_or_update_release() {
  [[ -n "$TITLE" ]] || TITLE="AIBA Browser $TAG"

  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "Release $TAG exists. Uploading/replacing assets"
    gh release upload "$TAG" "${ASSETS_TO_UPLOAD[@]}" --repo "$REPO" --clobber
    return 0
  fi

  local args=(
    "$TAG"
    "${ASSETS_TO_UPLOAD[@]}"
    "--repo" "$REPO"
    "--title" "$TITLE"
  )

  if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || die "Notes file not found: $NOTES_FILE"
    args+=("--notes-file" "$NOTES_FILE")
  else
    args+=("--notes" "$NOTES")
  fi

  if [[ "$CHANNEL" == "beta" ]]; then
    args+=("--prerelease")
  else
    args+=("--latest")
  fi

  log "Creating release $TAG"
  gh release create "${args[@]}"
}

trigger_and_wait_manifest_workflow() {
  local start_utc
  start_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  log "Triggering release-update-manifest.yml for tag=$TAG channel=$CHANNEL"
  gh workflow run release-update-manifest.yml --repo "$REPO" -f tag="$TAG" -f channel="$CHANNEL"

  local run_id=""
  local i
  for i in $(seq 1 24); do
    run_id="$(gh run list \
      --repo "$REPO" \
      --workflow release-update-manifest.yml \
      --limit 20 \
      --json databaseId,createdAt,status \
      --jq ".[] | select(.createdAt >= \"$start_utc\") | .databaseId" | head -n1 || true)"
    if [[ -n "$run_id" ]]; then
      break
    fi
    sleep 5
  done
  [[ -n "$run_id" ]] || die "Could not find triggered workflow run for release-update-manifest.yml"

  log "Watching workflow run id=$run_id"
  gh run watch "$run_id" --repo "$REPO" --exit-status
}

verify_release_metadata_assets() {
  local names
  names="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')"
  echo "$names" | grep -qx 'update-manifest.json' || die "Release missing update-manifest.json"
  echo "$names" | grep -qx 'update-manifest.sig' || die "Release missing update-manifest.sig"
  log "Release contains update-manifest.json and update-manifest.sig"
}

main() {
  parse_args "$@"
  [[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || die "Invalid channel: $CHANNEL"

  require_cmd gh
  require_cmd git
  require_cmd openssl
  require_cmd python3

  cd "$ROOT_DIR"

  ensure_auth
  ensure_secret
  push_updater_config
  ensure_remote_workflow_present
  ensure_assets
  create_or_update_release
  trigger_and_wait_manifest_workflow
  verify_release_metadata_assets

  local url
  url="$(gh release view "$TAG" --repo "$REPO" --json url --jq .url)"
  log "SUCCESS: $url"
}

main "$@"
