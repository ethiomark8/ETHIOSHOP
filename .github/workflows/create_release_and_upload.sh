#!/usr/bin/env bash
# create_release_and_upload.sh
#
# Create a GitHub Release (or update an existing release) and upload APK(s) and an optional ZIP.
#
# Requirements:
# - gh (GitHub CLI) installed and authenticated (`gh auth login`)
# - git (to infer repo) or set REPO environment variable as owner/repo
# - If you prefer the API path, set GITHUB_TOKEN with repo write permission
#
# Usage:
#   ./create_release_and_upload.sh -t <tag> -a "<apk_glob>" [-z] [-r owner/repo] [-d "<release notes>"]
#
# Example:
#   ./create_release_and_upload.sh -t v1.0.0 -a "app/build/outputs/apk/release/*.apk" -z -d "Initial signed release"
#
# What it does:
# - checks for existing release for the tag
# - if none exists: creates an annotated release and uploads APKs (and ZIP if -z)
# - if exists: uploads APKs (and ZIP if -z) and optionally updates title/notes
# - prints final release URL
#
set -euo pipefail

print_usage() {
  cat <<EOF
Usage: $0 -t <tag> -a "<apk_glob>" [-z] [-r owner/repo] [-d "<release notes>"] [--title "<release title>"]

  -t TAG               Release tag (required)
  -a APK_GLOB          Quoted glob (or space-separated list) of APK paths to upload, e.g. "app/build/outputs/apk/release/*.apk"
  -z                   Create and upload a zip of the APKs in addition to individual APKs
  -r REPO              Repository in owner/repo (defaults to git remote origin repository or env REPO)
  -d NOTES             Release notes/body (optional)
  --title TITLE        Release title (optional)
  -h                   Show this help
EOF
}

TAG=""
APK_GLOB=""
CREATE_ZIP=false
REPO="${REPO:-}"
NOTES=""
TITLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TAG="$2"; shift 2 ;;
    -a) APK_GLOB="$2"; shift 2 ;;
    -z) CREATE_ZIP=true; shift ;;
    -r) REPO="$2"; shift 2 ;;
    -d) NOTES="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    -h) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 1 ;;
  esac
done

if [ -z "$TAG" ] || [ -z "$APK_GLOB" ]; then
  echo "Tag and APK glob are required."
  print_usage
  exit 1
fi

# Try to infer repo if not provided
if [ -z "$REPO" ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    # get origin url -> owner/repo
    ORIGIN_URL=$(git config --get remote.origin.url || true)
    if [ -n "$ORIGIN_URL" ]; then
      # handle git@github.com:owner/repo.git and https://github.com/owner/repo.git
      REPO=$(echo "$ORIGIN_URL" | sed -E 's/.*[:\/]([^\/:]+\/[^\/:]+)(\.git)?$/\1/')
    fi
  fi
fi

if [ -z "$REPO" ]; then
  echo "Could not infer repo. Set REPO env var or pass -r owner/repo."
  exit 2
fi

echo "Repository: $REPO"
echo "Tag: $TAG"
echo "APK pattern(s): $APK_GLOB"
[ "$CREATE_ZIP" = true ] && echo "Will create ZIP of APKs."
[ -n "$TITLE" ] && echo "Title: $TITLE"
[ -n "$NOTES" ] && echo "Notes provided."

# Expand APK glob(s) into an array
shopt -s nullglob 2>/dev/null || true
APKS=()
# If user passed multiple patterns separated by spaces, expand them
eval "patterns=($APK_GLOB)"
for p in "${patterns[@]}"; do
  for file in $p; do
    APKS+=("$file")
  done
done

if [ ${#APKS[@]} -eq 0 ]; then
  echo "No APK files found for the provided pattern(s)."
  exit 3
fi

echo "Found ${#APKS[@]} APK(s):"
for f in "${APKS[@]}"; do echo "  - $f"; done

ZIP_NAME=""
if [ "$CREATE_ZIP" = true ]; then
  timestamp=$(date -u +%Y%m%d-%H%M%SZ)
  ZIP_NAME="apks-$TAG-$timestamp.zip"
  echo "Creating ZIP: $ZIP_NAME"
  # create zip containing APKs at top-level
  rm -f "$ZIP_NAME"
  zip -j "$ZIP_NAME" "${APKS[@]}" >/dev/null
  if [ ! -f "$ZIP_NAME" ]; then
    echo "Failed to create zip file."
    exit 4
  fi
fi

# Prefer gh CLI path
if command -v gh >/dev/null 2>&1; then
  echo "Using gh (GitHub CLI) to create/update release and upload assets."

  # Check if release exists
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists — uploading assets to existing release."
    # upload APKs
    for f in "${APKS[@]}"; do
      echo "Uploading $f ..."
      gh release upload "$TAG" "$f" --repo "$REPO" --clobber
    done
    if [ -n "$ZIP_NAME" ]; then
      echo "Uploading $ZIP_NAME ..."
      gh release upload "$TAG" "$ZIP_NAME" --repo "$REPO" --clobber
    fi
    # update title/notes if provided
    if [ -n "$TITLE" ] || [ -n "$NOTES" ]; then
      args=()
      [ -n "$TITLE" ] && args+=(--title "$TITLE")
      [ -n "$NOTES" ] && args+=(--notes "$NOTES")
      if [ ${#args[@]} -gt 0 ]; then
        gh release edit "$TAG" --repo "$REPO" "${args[@]}"
      fi
    fi
  else
    echo "Creating new release $TAG ..."
    create_args=( "$TAG" )
    # add assets
    for f in "${APKS[@]}"; do create_args+=( "$f" ); done
    [ -n "$ZIP_NAME" ] && create_args+=( "$ZIP_NAME" )
    [ -n "$TITLE" ] && create_args+=( --title "$TITLE" )
    if [ -n "$NOTES" ]; then
      create_args+=( --notes "$NOTES" )
    else
      create_args+=( --notes "" )
    fi
    # shell-expand array safely when calling gh
    gh release create --repo "$REPO" "${create_args[@]}"
  fi

  # print release URL
  RELEASE_URL=$(gh release view "$TAG" --repo "$REPO" --json url --jq '.url')
  echo "Release URL: $RELEASE_URL"

else
  # Fallback: use GitHub API with curl and GITHUB_TOKEN
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "gh CLI not found and GITHUB_TOKEN is not set. Install gh or set GITHUB_TOKEN to use the API fallback."
    exit 5
  fi

  API="https://api.github.com"
  # Check if release exists
  release_id=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API/repos/$REPO/releases/tags/$TAG" | jq -r '.id // empty' || true)
  if [ -n "$release_id" ]; then
    echo "Release exists (id: $release_id) — uploading assets."
  else
    echo "Creating release via API..."
    payload=$(jq -n --arg tag "$TAG" --arg name "${TITLE:-$TAG}" --arg body "${NOTES}" '{ tag_name: $tag, name: $name, body: $body, draft: false, prerelease: false }')
    resp=$(curl -s -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/json" -d "$payload" "$API/repos/$REPO/releases")
    release_id=$(echo "$resp" | jq -r '.id')
    if [ -z "$release_id" ] || [ "$release_id" = "null" ]; then
      echo "Failed to create release: $resp"
      exit 6
    fi
  fi

  # upload assets
  upload_url="https://uploads.github.com/repos/$REPO/releases/$release_id/assets"
  for f in "${APKS[@]}"; do
    name=$(basename "$f")
    echo "Uploading $f as $name ..."
    curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/vnd.android.package-archive" \
      "$upload_url?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name")" \
      --data-binary @"$f" >/dev/null
  done
  if [ -n "$ZIP_NAME" ]; then
    name=$(basename "$ZIP_NAME")
    echo "Uploading $ZIP_NAME as $name ..."
    curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/zip" \
      "$upload_url?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$name")" \
      --data-binary @"$ZIP_NAME" >/dev/null
  fi
  echo "Completed uploads via API. Visit: https://github.com/$REPO/releases/tag/$TAG"
fi

echo "Done."
