#!/bin/bash
# Archive the Release build, export it for App Store Connect, optionally upload it.
# Run from a clean checkout of a release/*, hotfix/* branch or a v* tag.
# Signing team and OAuth ids come from Config/Local.xcconfig and Config/Secrets.xcconfig
# (gitignored); this script never prints their values.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/app-store-archive.sh [--export-only | --upload] [--help]

  --export-only  (default) archive, then export a signed .pkg to build/AppStore/export
  --upload       archive, then send the build to App Store Connect (Xcode sets the
                 build number). Refused unless the git checks pass.
  --help         show this text

Optional App Store Connect API key (otherwise the Xcode account is used):
  ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID

Set PV_SKIP_GIT_CHECK=1 to skip the branch and clean-tree checks for a local
dry run of --export-only. It is refused together with --upload.
USAGE
}

mode=export
for arg in "$@"; do
  case "$arg" in
    --export-only) mode=export ;;
    --upload) mode=upload ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

cd "$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
out=build/AppStore
archive=$out/PhotoVault.xcarchive
export_dir=$out/export
project=(-project PhotoVault.xcodeproj -scheme PhotoVault)

# --- Preflight: git state and version ---------------------------------------
version=$(awk -F= '/^MARKETING_VERSION/ {gsub(/[ \t]/, "", $2); print $2}' Config/Version.xcconfig)
[ -n "$version" ] || fail "MARKETING_VERSION not found in Config/Version.xcconfig"

if [ "${PV_SKIP_GIT_CHECK:-}" = 1 ]; then
  [ "$mode" = upload ] && fail "PV_SKIP_GIT_CHECK cannot be combined with --upload"
  echo "warning: git checks skipped (PV_SKIP_GIT_CHECK=1)" >&2
else
  [ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
  branch=$(git symbolic-ref --short -q HEAD || true)
  ref_version=
  if [ -n "$branch" ]; then
    case "$branch" in
      release/*|hotfix/*) ref_version=${branch#*/} ;;
      *) fail "branch '$branch' is not release/* or hotfix/*" ;;
    esac
  else
    tag=$(git describe --exact-match --tags --match 'v*' HEAD 2>/dev/null || true)
    [ -n "$tag" ] || fail "detached HEAD without a v* tag"
    ref_version=${tag#v}
  fi
  # hotfix branches are named after an issue, not a version: only compare for releases and tags.
  case "$branch" in
    hotfix/*) ;;
    *) [ "$ref_version" = "$version" ] || fail "MARKETING_VERSION $version does not match ref version $ref_version" ;;
  esac
fi
echo "commit $(git rev-parse --short HEAD), MARKETING_VERSION $version"

# --- Preflight: build settings (values never printed) -----------------------
settings=$(xcodebuild "${project[@]}" -configuration Release -showBuildSettings 2>/dev/null) \
  || fail "xcodebuild -showBuildSettings failed"
setting() { printf '%s\n' "$settings" | awk -v k="$1" '$1 == k && $2 == "=" {sub(/^[^=]*= ?/, ""); print; exit}'; }

[ -n "$(setting DEVELOPMENT_TEAM)" ] || fail "DEVELOPMENT_TEAM is empty (set it in Config/Local.xcconfig)"
for key in GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET; do
  if [ -n "$(setting "$key")" ]; then echo "info: $key: set"; else echo "info: $key: missing" >&2; missing=1; fi
done
[ -z "${missing:-}" ] || fail "Google OAuth settings missing (set them in Config/Secrets.xcconfig)"
ok "DEVELOPMENT_TEAM is set"
# The store build must not carry the browser Google Drive import.
store_flag=(GOOGLE_DRIVE_BROWSER_IMPORT=NO)
if [ -n "$(setting DROPBOX_APP_KEY)" ]; then
  echo "info: DROPBOX_APP_KEY: set"
else
  echo "warning: DROPBOX_APP_KEY is empty; Dropbox import will be hidden" >&2
fi

auth=()
if [ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]; then
  if [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  else
    fail "set all of ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, or none"
  fi
fi

# --- Archive ----------------------------------------------------------------
rm -rf "$archive" "$export_dir" "$out/expanded"
mkdir -p "$out"
xcodebuild archive "${project[@]}" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} "${store_flag[@]}" \
  || fail "xcodebuild archive failed"

# --- Post-archive checks ----------------------------------------------------
app=$archive/Products/Applications/PhotoVault.app
[ -d "$app" ] || fail "archive has no PhotoVault.app"
ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null) || fail "cannot read entitlements from the archive"
for key in com.apple.security.app-sandbox com.apple.security.network.server keychain-access-groups; do
  printf '%s' "$ents" | grep -q "$key" || fail "entitlement $key missing from the archived app"
done
ok "archived app has sandbox, network.server and keychain-access-groups"

check_bundle() { # $1 = app path
  local a=$1 plist=$1/Contents/Info.plist v
  [ -f "$a/Contents/Resources/PrivacyInfo.xcprivacy" ] || fail "PrivacyInfo.xcprivacy missing"
  [ -d "$a/Contents/Resources/en.lproj" ] || fail "en.lproj missing"
  [ -d "$a/Contents/Resources/vi.lproj" ] || fail "vi.lproj missing"
  v=$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$plist" 2>/dev/null || true)
  [ "$v" = false ] || fail "ITSAppUsesNonExemptEncryption is not false"
  v=$(/usr/libexec/PlistBuddy -c 'Print :PVGoogleDriveBrowserImport' "$plist" 2>/dev/null || true)
  [ "$v" = false ] || [ "$v" = NO ] || fail "PVGoogleDriveBrowserImport is not NO (needs the store flag from the Info.plist change)"
}
check_bundle "$app"
ok "privacy manifest, localizations and Info.plist keys"

# --- Export, check the distribution-signed app, then upload ------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export_app() { # $1 = destination (export|upload), $2 = export path
  local opts=$tmp/ExportOptions-$1.plist
  cp Config/ExportOptions-AppStore.plist "$opts"
  /usr/libexec/PlistBuddy -c "Set :destination $1" "$opts"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$2" \
    -exportOptionsPlist "$opts" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
    || fail "xcodebuild -exportArchive ($1) failed (an Apple Distribution certificate, a Mac Installer Distribution certificate and an App Store profile are needed)"
}

export_app export "$export_dir"
pkg=$(ls "$export_dir"/*.pkg 2>/dev/null | head -n 1 || true)
[ -n "$pkg" ] || fail "export produced no .pkg"
pkgutil --expand-full "$pkg" "$out/expanded" || fail "cannot expand $pkg"
exported=$(find "$out/expanded" -maxdepth 4 -name PhotoVault.app | head -n 1)
[ -n "$exported" ] || fail "exported package has no PhotoVault.app"
exp_ents=$(codesign -d --entitlements - --xml "$exported" 2>/dev/null) || fail "cannot read entitlements from the exported app"
for key in com.apple.security.app-sandbox com.apple.security.network.server keychain-access-groups; do
  printf '%s' "$exp_ents" | grep -q "$key" || fail "entitlement $key missing from the exported app"
done
if printf '%s' "$exp_ents" | grep -q get-task-allow; then
  fail "exported app still has get-task-allow"
fi
check_bundle "$exported"
ok "exported $pkg passes the distribution checks"

if [ "$mode" = upload ]; then
  export_app upload "$out/upload"
  ok "uploaded to App Store Connect; Xcode set the build number; the build appears in TestFlight after processing"
fi
