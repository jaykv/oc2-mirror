#!/usr/bin/env bash
#
# mirror.sh — Mirror opencode v2 (opencode2) binaries from npm to GitHub releases.
#
# Upstream (anomalyco/opencode) publishes the v2 CLI binaries to npm as
# @opencode/cli plus per-architecture packages (@opencode/cli-<os>-<arch>),
# and serves them from opencode.ai — but does NOT attach them to GitHub
# releases. This script pulls the official npm-published binaries, verifies
# their registry integrity hashes, and publishes them as GitHub release
# assets. Each asset is the unmodified official binary, named opencode2-*
# (opencode2 is the legacy alias the official installer keeps for the v2
# `opencode` binary).
#
# Env:
#   NPM_TAG   npm dist-tag to mirror (default: latest). e.g. latest | beta | dev
#   ONLY      optional comma-separated target filter, e.g. ONLY=linux-x64
#   DRY_RUN   set to 1 to download/verify/extract without creating a release
#   GITHUB_REPOSITORY  owner/repo (set automatically in GitHub Actions)
#
set -euo pipefail

NPM_TAG="${NPM_TAG:-latest}"
PKG="${PKG:-@opencode/cli}"
REPO="${GITHUB_REPOSITORY:-}"
DRY_RUN="${DRY_RUN:-0}"
ONLY="${ONLY:-}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

log() { echo "[mirror] $*" >&2; }
fail() { echo "[mirror] ERROR: $*" >&2; exit 1; }

# 1. Resolve npm dist-tag -> version
log "resolving dist-tag '$NPM_TAG' for $PKG"
TAGS_JSON="$(curl -fsSL "https://registry.npmjs.org/-/package/${PKG}/dist-tags")"
VERSION="$(echo "$TAGS_JSON" | jq -r --arg tag "$NPM_TAG" '.[$tag] // empty')"
[ -n "$VERSION" ] || fail "no version found for dist-tag '$NPM_TAG'"
TAG="v$VERSION"
log "dist-tag $NPM_TAG -> $VERSION (release tag $TAG)"

# 2. Skip if this version is already mirrored
if [ -n "$REPO" ] && [ "$DRY_RUN" != "1" ]; then
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "release $TAG already exists in $REPO, nothing to do"
    exit 0
  fi
fi

# 3. Capture official update-channel provenance (best effort)
UPDATE_JSON="$(curl -fsSL "https://opencode.ai/update/api/latest/cli/npm" || true)"
UPDATE_VERSION="$(echo "$UPDATE_JSON" | jq -r '.version // empty' 2>/dev/null || true)"
UPDATE_SHA="$(echo "$UPDATE_JSON" | jq -r '.metadata.github.sha // empty' 2>/dev/null || true)"
UPDATE_RUN="$(echo "$UPDATE_JSON" | jq -r '.metadata.github.run_id // empty' 2>/dev/null || true)"

# 4. Read per-arch binary packages from the stub package metadata
META="$(curl -fsSL "https://registry.npmjs.org/${PKG}/${VERSION}")"
mapfile -t entries < <(echo "$META" | jq -r '.optionalDependencies | to_entries[] | "\(.key)=\(.value)"')
[ "${#entries[@]}" -gt 0 ] || fail "no optionalDependencies in $PKG@$VERSION metadata"

mkdir -p assets
: > SHA256SUMS.txt
: > SOURCES.txt

for e in "${entries[@]}"; do
  name="${e%%=*}"
  ver="${e#*=}"
  short="${name##*/}"            # cli-linux-x64
  target="${short#cli-}"        # linux-x64

  if [ -n "$ONLY" ]; then
    case ",$ONLY," in
      *",$target,"*) ;;
      *) log "skipping $target (ONLY filter)"; continue ;;
    esac
  fi

  log "fetching $name@$ver"
  pkgmeta="$(curl -fsSL "https://registry.npmjs.org/${name}/${ver}")"
  tarball="$(echo "$pkgmeta" | jq -r '.dist.tarball // empty')"
  integrity="$(echo "$pkgmeta" | jq -r '.dist.integrity // empty')"
  [ -n "$tarball" ] && [ -n "$integrity" ] || fail "missing dist info for $name@$ver"

  curl -fsSL -o pkg.tgz "$tarball"

  # Verify npm registry integrity hash (sha512-base64)
  algo="${integrity%%-*}"
  b64="${integrity#*-}"
  if [ "$algo" = "sha512" ]; then
    want="$(printf '%s' "$b64" | base64 -d | od -An -tx1 | tr -d ' \n')"
    got="$(sha512sum pkg.tgz | awk '{print $1}')"
    [ "$want" = "$got" ] || fail "integrity mismatch for $name@$ver"
    log "integrity OK: $name"
  else
    fail "unexpected integrity algorithm '$algo' for $name@$ver"
  fi

  tar -xzf pkg.tgz
  # v2 per-arch tarballs ship the binary as package/bin/opencode[.exe]
  if [ -f "package/bin/opencode.exe" ]; then
    asset="opencode2-${target}.exe"
    cp "package/bin/opencode.exe" "assets/$asset"
  elif [ -f "package/bin/opencode" ]; then
    asset="opencode2-${target}"
    cp "package/bin/opencode" "assets/$asset"
    chmod +x "assets/$asset"
  else
    fail "no opencode binary found in $name@$ver"
  fi
  ( cd assets && sha256sum "$asset" >> ../SHA256SUMS.txt )
  echo "$name@$ver <- $tarball" >> SOURCES.txt
  rm -rf package pkg.tgz
  log "staged assets/$asset"
done

[ -s SHA256SUMS.txt ] || fail "no assets were staged"

if [ "$DRY_RUN" = "1" ]; then
  log "dry run complete, assets:"
  ls -la assets/
  cat SHA256SUMS.txt
  exit 0
fi

[ -n "$REPO" ] || fail "GITHUB_REPOSITORY is not set; refusing to create release"

# 5. Build release notes with provenance
{
  echo "Unofficial mirror of the **opencode v2** binaries for \`$PKG@$VERSION\` (npm dist-tag \`$NPM_TAG\`)."
  echo
  echo "Upstream does not attach v2 binaries to GitHub releases; they are"
  echo "distributed via npm and opencode.ai-hosted files. Each binary below is"
  echo "the unmodified official build, extracted from its npm package and"
  echo "verified against the registry-published sha512 integrity hash before"
  echo "upload. Assets are named \`opencode2-*\` — \`opencode2\` is the alias the"
  echo "official installer keeps for the v2 \`opencode\` binary."
  echo
  echo "Verify downloads against \`SHA256SUMS.txt\`."
  echo
  echo "## Provenance"
  echo
  echo "- Mirrored: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Upstream repo: https://github.com/anomalyco/opencode"
  echo "- npm package: https://www.npmjs.com/package/${PKG}/v/${VERSION}"
  if [ -n "$UPDATE_VERSION" ]; then
    echo "- opencode.ai update channel: latest -> $UPDATE_VERSION"
  fi
  if [ -n "$UPDATE_SHA" ]; then
    echo "- upstream build: commit $UPDATE_SHA (actions run $UPDATE_RUN)"
  fi
  echo
  echo "## Sources"
  echo
  sed 's/^/- /' SOURCES.txt
  echo
  echo "## SHA256"
  echo
  echo '```'
  cat SHA256SUMS.txt
  echo '```'
} > notes.md

# 6. Create the release and upload assets
log "creating release $TAG in $REPO"
# shellcheck disable=SC2086
gh release create "$TAG" \
  --repo "$REPO" \
  --title "opencode2 v$VERSION" \
  --notes-file notes.md \
  assets/* SHA256SUMS.txt

log "mirror complete: $TAG"
