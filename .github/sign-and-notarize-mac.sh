#!/usr/bin/env bash
# mac-dmg.yml: sign-and-notarize-mac.sh <folder holding TakeoffPal.app> <dmg to make>
# With all six APPLE_* secrets set, signs every Mach-O in the app and then the app with the Developer ID, makes and signs
# the DMG, notarizes and staples it, and fails unless codesign, stapler and Gatekeeper all accept the result. Without
# them, makes the same unsigned DMG as before. Secret values are never printed; the keychain and the key files live only
# in $RUNNER_TEMP/apple, which mac-dmg.yml always deletes.
set -euo pipefail
folder=$1 dmg=$2
app="$folder/TakeoffPal.app"
reader="$app/Contents/Resources/bundle/reader/"
entitlements="$(cd "$(dirname "$0")" && pwd)/mac-reader-entitlements.plist"

make_dmg() {
  ln -s /Applications "$folder/Applications"
  hdiutil create -volname TakeoffPal -srcfolder "$folder" -ov -format UDZO "$dmg"
}

missing=""
for name in APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_TEAM_ID APPLE_API_KEY APPLE_API_KEY_ID \
    APPLE_API_ISSUER; do
  [ -n "${!name:-}" ] || missing="$missing $name"
done
if [ -n "$missing" ]; then
  echo "::notice::The DMG is unsigned: these Apple secrets are not set:$missing"
  make_dmg
  exit 0
fi

# A keychain only this run uses, under a password made here; the .p12 is deleted as soon as it is imported.
work="$RUNNER_TEMP/apple" keychain="$RUNNER_TEMP/apple/signing.keychain-db"
mkdir -m 700 "$work"
(umask 077
  printf '%s' "$APPLE_DEVELOPER_ID_P12" | base64 --decode > "$work/developer-id.p12"
  printf '%s\n' "$APPLE_API_KEY" > "$work/api-key.p8")
keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/developer-id.p12" -k "$keychain" -f pkcs12 -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
rm "$work/developer-id.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain"
identity="$(security find-identity -v -p codesigning "$keychain" | grep -F "($APPLE_TEAM_ID)\"" \
  | awk '/"Developer ID Application: / {print $2; exit}' || true)"
[ -n "$identity" ] || { echo "::error::APPLE_DEVELOPER_ID_P12 has no valid Developer ID Application identity for APPLE_TEAM_ID"; exit 1; }

# Inside-out: every Mach-O in the app, deepest first, then the app. All of them sit under Contents/Resources/bundle
# (Python, its native libraries, and OpenAI's Codex in bundle/reader); there are no nested bundles. Only Codex's
# executables get entitlements: codex and codex-code-mode-host embed V8, which needs allow-jit and
# allow-unsigned-executable-memory (OpenAI signs them with exactly these two). Python needs none: its libffi uses
# trampoline tables, not writable code. Library validation stays on, since every library is signed here by this team.
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
find "$app/Contents" -type f | awk -F/ '{print NF "\t" $0}' | sort -rn | cut -f2- | while IFS= read -r file; do
  kind="$(file -b "$file")"
  if [[ "$kind" == Mach-O*executable* && "$file" == "$reader"* ]]; then
    sign --entitlements "$entitlements" "$file"
  elif [[ "$kind" == Mach-O* ]]; then
    sign "$file"
  fi
done
sign "$app"

make_dmg
codesign --force --timestamp --sign "$identity" "$dmg"

notary() { xcrun notarytool "$@" --key "$work/api-key.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"; }
notary submit "$dmg" --wait --timeout 40m --output-format plist | tee "$work/notary.plist" || true
status="$(plutil -extract status raw -o - "$work/notary.plist" 2> /dev/null || true)"
id="$(plutil -extract id raw -o - "$work/notary.plist" 2> /dev/null || true)"
if [ "$status" != Accepted ]; then
  [ -z "$id" ] || notary log "$id" || true
  echo "::error::The notary service did not accept the DMG (${status:-no answer})"
  exit 1
fi
xcrun stapler staple "$dmg"

# Check what ships: the stapled DMG, and the app as it comes out of it.
gatekeeper() {  # Gatekeeper must accept it as notarized Developer ID code, not just signed code.
  local out status=0
  out="$(spctl -a -vvv "$@" 2>&1)" || status=$?
  echo "$out"
  [[ $status == 0 && "$out" == *"source=Notarized Developer ID"* ]] || { echo "::error::Gatekeeper rejects $*"; exit 1; }
}
xcrun stapler validate "$dmg"
codesign --verify --deep --strict --verbose=2 "$dmg"
gatekeeper -t open --context context:primary-signature "$dmg"
mount="$RUNNER_TEMP/mounted"
mkdir "$mount"
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" > /dev/null
codesign --verify --deep --strict --verbose=2 "$mount/TakeoffPal.app"
gatekeeper -t exec "$mount/TakeoffPal.app"
hdiutil detach "$mount" > /dev/null
echo "Signed, notarized and stapled: $dmg"
