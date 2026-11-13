#!/usr/bin/env bash
# Builds a release of Subzero for distribution via a Homebrew tap.
#
# Usage:
#   Scripts/release.sh <version> [--publish]
#
# Environment:
#   APP_IDENTITY    Developer ID signing identity, e.g.
#                   "Developer ID Application: Name (TEAMID)".
#                   Empty -> ad-hoc signature (local testing only).
#   NOTARY_PROFILE  notarytool keychain profile, created once with:
#                   xcrun notarytool store-credentials <profile> \
#                     --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
#                   Empty -> notarization is skipped.
#   GITHUB_REPO     owner/name of the app repository (default: from git remote "origin").
#   ARCHES          Architectures to build (default: "arm64 x86_64").
#   BUILD_NUMBER    CFBundleVersion (default: number of git commits).
#
# Output (in dist/):
#   Subzero-<version>.zip   archive to attach to the GitHub release
#   subzero.rb              ready-to-commit cask for the tap repository
#
# --publish creates GitHub release v<version> with the zip via `gh`.
# Requires a Developer ID signature and notarization.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
  exit "${1:-1}"
}

VERSION=""
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    -h|--help) usage 0 ;;
    -*) echo "Unknown option: $arg" >&2; usage ;;
    *) VERSION="$arg" ;;
  esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: version must look like 1.2.3 (got '${VERSION}')" >&2
  usage
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=${APP_NAME:-Subzero}
BUNDLE_ID=${BUNDLE_ID:-com.klyuzhevigor.subzero}
CASK_TOKEN=$(tr '[:upper:]' '[:lower:]' <<<"$APP_NAME")
APP_IDENTITY=${APP_IDENTITY:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
ARCHES=${ARCHES:-"arm64 x86_64"}
DIST="$ROOT/dist"
APP="$ROOT/${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP="$DIST/$ZIP_NAME"
TAG="v${VERSION}"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------

if [[ -z "${GITHUB_REPO:-}" ]]; then
  REMOTE=$(git remote get-url origin 2>/dev/null || true)
  GITHUB_REPO=$(sed -E -n 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?$#\2#p' <<<"$REMOTE")
fi
GITHUB_REPO=${GITHUB_REPO:-OWNER/subzero}

if git rev-parse --git-dir >/dev/null 2>&1; then
  BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
  if [[ -n "$(git status --porcelain)" ]]; then
    warn "working tree has uncommitted changes"
  fi
else
  BUILD_NUMBER=${BUILD_NUMBER:-1}
fi

SIGNED=0
if [[ -n "$APP_IDENTITY" ]]; then
  security find-identity -v -p codesigning | grep -qF "$APP_IDENTITY" \
    || die "signing identity not found in keychain: $APP_IDENTITY"
  [[ "$APP_IDENTITY" == "Developer ID Application:"* ]] \
    || warn "identity is not 'Developer ID Application' — Gatekeeper will reject it outside this Mac"
  SIGNED=1
else
  warn "APP_IDENTITY is empty: ad-hoc signature, the build is for local testing only"
fi

if [[ -n "$NOTARY_PROFILE" && $SIGNED -eq 0 ]]; then
  die "NOTARY_PROFILE requires APP_IDENTITY"
fi

if [[ $PUBLISH -eq 1 ]]; then
  [[ $SIGNED -eq 1 && -n "$NOTARY_PROFILE" ]] \
    || die "--publish requires APP_IDENTITY and NOTARY_PROFILE"
  [[ "$GITHUB_REPO" != OWNER/* ]] || die "set GITHUB_REPO or add git remote 'origin'"
  command -v gh >/dev/null || die "gh CLI not found"
  [[ -z "$(git status --porcelain)" ]] || die "--publish requires a clean working tree"
fi

# --- Tests & build -----------------------------------------------------------

log "Running tests"
swift test

log "Building ${APP_NAME} ${VERSION} (${BUILD_NUMBER}) for: ${ARCHES}"
ARCHES="$ARCHES" \
MARKETING_VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
APP_IDENTITY="$APP_IDENTITY" \
APP_NAME="$APP_NAME" \
BUNDLE_ID="$BUNDLE_ID" \
  "$ROOT/Scripts/package_app.sh" release

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"

rm -rf "$DIST"
mkdir -p "$DIST"

make_zip() {
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
}

make_zip

# --- Notarization ------------------------------------------------------------

NOTARIZED=0
if [[ -n "$NOTARY_PROFILE" ]]; then
  log "Notarizing (this usually takes a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  log "Stapling ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  # Rebuild the archive so it carries the stapled app.
  make_zip

  log "Gatekeeper assessment"
  spctl --assess --type execute --verbose=2 "$APP"
  NOTARIZED=1
else
  warn "NOTARY_PROFILE is empty: notarization skipped, Gatekeeper will block the app after download"
fi

SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')

# --- Cask ----------------------------------------------------------------------

log "Rendering cask"
CASK="$DIST/${CASK_TOKEN}.rb"
sed \
  -e "s|@TOKEN@|${CASK_TOKEN}|g" \
  -e "s|@VERSION@|${VERSION}|g" \
  -e "s|@SHA256@|${SHA256}|g" \
  -e "s|@REPO@|${GITHUB_REPO}|g" \
  -e "s|@APP_NAME@|${APP_NAME}|g" \
  -e "s|@BUNDLE_ID@|${BUNDLE_ID}|g" \
  "$ROOT/Packaging/cask.rb.template" > "$CASK"

# --- Publish -------------------------------------------------------------------

if [[ $PUBLISH -eq 1 ]]; then
  log "Creating GitHub release ${TAG} in ${GITHUB_REPO}"
  gh release create "$TAG" "$ZIP" \
    --repo "$GITHUB_REPO" \
    --title "${APP_NAME} ${VERSION}" \
    --generate-notes
fi

# --- Summary -------------------------------------------------------------------

cat <<EOF

Done.
  Version:    ${VERSION} (${BUILD_NUMBER})
  Archive:    ${ZIP}
  SHA-256:    ${SHA256}
  Cask:       ${CASK}
  Signed:     $([[ $SIGNED -eq 1 ]] && echo "Developer ID" || echo "ad-hoc (NOT for distribution)")
  Notarized:  $([[ $NOTARIZED -eq 1 ]] && echo yes || echo no)
EOF

if [[ $PUBLISH -eq 0 && $NOTARIZED -eq 1 ]]; then
  cat <<EOF

Next:
  gh release create ${TAG} "${ZIP}" --repo ${GITHUB_REPO} --generate-notes
  cp "${CASK}" <tap-repo>/Casks/ && commit && push
EOF
fi
