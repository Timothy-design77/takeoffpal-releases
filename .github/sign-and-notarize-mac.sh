#!/bin/sh
# Sign TakeoffPal.app or notarize and staple the DMG with Tim's Developer ID.
# Called from mac-dmg.yml only when the Apple repository secrets are all set.
# Never print secret values. Never use set -x.
set -eu
set -o pipefail

usage() {
  echo "usage: $0 app <TakeoffPal.app> | dmg <TakeoffPal-Mac-arm64.dmg>" >&2
  exit 2
}

[ "${1:-}" = app ] || [ "${1:-}" = dmg ] || usage
[ -n "${2:-}" ] || usage
TARGET=$2
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENTITLEMENTS="$ROOT/macos-entitlements.plist"

need() {
  eval "val=\${$1:-}"
  [ -n "$val" ] || { echo "missing \$$1" >&2; exit 1; }
}

need APPLE_DEVELOPER_ID_P12
need APPLE_DEVELOPER_ID_P12_PASSWORD
need APPLE_API_KEY
need APPLE_API_KEY_ID
need APPLE_API_ISSUER

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/takeoffpal-sign.XXXXXX")
KEYCHAIN="$WORKDIR/build.keychain-db"
KEYCHAIN_PW=
cleanup() {
  if [ -n "${KEYCHAIN_PW:-}" ] && [ -f "$KEYCHAIN" ]; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

chmod 700 "$WORKDIR"
# The secret is the base64 of the .p12 bytes.
printf '%s' "$APPLE_DEVELOPER_ID_P12" | base64 --decode > "$WORKDIR/cert.p12"
chmod 600 "$WORKDIR/cert.p12"
# The .p8 body, including the PEM header.
printf '%s' "$APPLE_API_KEY" > "$WORKDIR/AuthKey.p8"
# Restore a trailing newline if the secret was stored without one (PEM parsers expect it).
[ -n "$(tail -c1 "$WORKDIR/AuthKey.p8")" ] && printf '\n' >> "$WORKDIR/AuthKey.p8"
chmod 600 "$WORKDIR/AuthKey.p8"

KEYCHAIN_PW=$(openssl rand -base64 32)
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security import "$WORKDIR/cert.p12" -k "$KEYCHAIN" -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
# Put the build keychain first without dropping the runner's default keychains.
OLD_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
security list-keychains -d user -s "$KEYCHAIN" $OLD_KEYCHAINS
security default-keychain -s "$KEYCHAIN"

IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/{print $2; exit}')
[ -n "$IDENTITY" ] || { echo "no Developer ID Application identity in the imported certificate" >&2; exit 1; }
echo "Using codesign identity: $IDENTITY"

sign_macho() {
  app=$1
  # Deepest Mach-O files first, then the .app bundle. The launcher may be a shell script (not Mach-O).
  find "$app" -type f ! -name '.*' -print0 | while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
      *Mach-O*) printf '%s\n' "$f" ;;
    esac
  done | awk '{print length($0), $0}' | sort -nr | cut -d' ' -f2- | while IFS= read -r bin; do
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$bin"
  done
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$app"
}

if [ "$1" = app ]; then
  [ -d "$TARGET" ] || { echo "not an app bundle: $TARGET" >&2; exit 1; }
  sign_macho "$TARGET"
  codesign --verify --deep --strict --verbose=2 "$TARGET"
  echo "signed app: $TARGET"
  exit 0
fi

[ -f "$TARGET" ] || { echo "not a DMG: $TARGET" >&2; exit 1; }
codesign --force --timestamp --sign "$IDENTITY" "$TARGET"
xcrun notarytool submit "$TARGET" --key "$WORKDIR/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" --wait
xcrun stapler staple "$TARGET"
codesign --verify --deep --strict --verbose=2 "$TARGET"
spctl -a -vvv --type open --context context:primary-signature "$TARGET"
xcrun stapler validate "$TARGET"
# Confirm the app inside the stapled DMG is accepted for execution.
MOUNT=$(hdiutil attach -nobrowse -readonly -mountrandom /tmp "$TARGET" | awk -F'\t' '/\/tmp\//{print $NF; exit}')
[ -n "$MOUNT" ] || { echo "failed to mount $TARGET" >&2; exit 1; }
detach() { hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || true; }
trap 'detach; cleanup' EXIT INT TERM
APP=
for cand in "$MOUNT"/TakeoffPal.app "$MOUNT"/*.app; do
  if [ -d "$cand" ]; then APP=$cand; break; fi
done
[ -n "$APP" ] || { echo "no .app in $TARGET" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vvv --type exec "$APP"
detach
trap cleanup EXIT INT TERM
echo "notarized and stapled: $TARGET"
