#!/bin/bash

set -euo pipefail

VERSION="${1:?usage: verify-release-artifacts.sh VERSION [ARTIFACT_DIRECTORY]}"
ARTIFACT_DIR="${2:-.}"
DMG="$ARTIFACT_DIR/Captures-$VERSION.dmg"
ZIP="$ARTIFACT_DIR/Captures-$VERSION.zip"
WORK_DIR="$(mktemp -d)"
MOUNT_POINT="$WORK_DIR/dmg"
MOUNTED=false

cleanup() {
  if [ "$MOUNTED" = true ]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

verify_app() {
  local app="$1"
  local source="$2"

  if [ ! -d "$app" ]; then
    echo "Captures.app is missing from $source" >&2
    exit 1
  fi

  codesign --verify --deep --strict --verbose=2 "$app"
  local signature_info
  signature_info="$(codesign -dv --verbose=4 "$app" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<< "$signature_info"
  spctl --assess --type execute --verbose=4 "$app"
  xcrun stapler validate "$app"

  local plist="$app/Contents/Info.plist"
  test "$(plutil -extract CFBundlePackageType raw "$plist")" = "APPL"
  test "$(plutil -extract CFBundleShortVersionString raw "$plist")" = "$VERSION"
  test -n "$(plutil -extract CFBundleVersion raw "$plist")"
  local architectures
  architectures="$(lipo -archs "$app/Contents/MacOS/Captures")"
  for required_arch in arm64 x86_64; do
    case " $architectures " in
      *" $required_arch "*) ;;
      *) echo "Missing $required_arch architecture in $source" >&2; exit 1 ;;
    esac
  done
  test -f "$app/Contents/Resources/LICENSE"
  test -f "$app/Contents/Resources/NOTICE"
}

test -f "$DMG"
test -f "$ZIP"

if [ -f "$ARTIFACT_DIR/SHA256SUMS" ]; then
  (cd "$ARTIFACT_DIR" && shasum -a 256 -c SHA256SUMS)
fi

codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

mkdir -p "$WORK_DIR/zip"
ditto -x -k "$ZIP" "$WORK_DIR/zip"
verify_app "$WORK_DIR/zip/Captures.app" "the ZIP"

mkdir -p "$MOUNT_POINT"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED=true
verify_app "$MOUNT_POINT/Captures.app" "the DMG"

if [ -f "$ARTIFACT_DIR/Captures-latest.dmg" ]; then
  cmp "$DMG" "$ARTIFACT_DIR/Captures-latest.dmg"
fi

echo "Verified signed and notarized Captures $VERSION release artifacts."
