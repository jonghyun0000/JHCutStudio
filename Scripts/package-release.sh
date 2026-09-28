#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${JHCUT_SIGN_IDENTITY:?Developer ID Application identity is required}"
: "${JHCUT_NOTARY_PROFILE:?A previously configured notarytool keychain profile is required}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
bundle="${JHCUT_RELEASE_BUNDLE:-Build/JH CUT Studio.app}"
output="${JHCUT_RELEASE_DIRECTORY:-Build/Distribution}"
mkdir -p "$output"
# Refuse to sign or submit a bundle that fails the credential-free checks.
bash Scripts/release-preflight.sh "$bundle" || { echo "Preflight failed; nothing was signed or submitted."; exit 1; }
# Explicit invocation with supplied identities only; no automatic credential lookup or submission on build.
codesign --force --options runtime --timestamp --sign "$JHCUT_SIGN_IDENTITY" "$bundle/Contents/Resources/Whisper/whisper-cli"
codesign --force --options runtime --timestamp --sign "$JHCUT_SIGN_IDENTITY" "$bundle/Contents/Frameworks/libJHCutCore.dylib"
codesign --force --options runtime --timestamp --sign "$JHCUT_SIGN_IDENTITY" "$bundle"
codesign --verify --deep --strict "$bundle"
# Hardened runtime library validation needs the app and the dylib to carry the SAME Team ID.
app_team=$(codesign -dv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p'); lib_team=$(codesign -dv "$bundle/Contents/Frameworks/libJHCutCore.dylib" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ -z "$app_team" || "$app_team" == "not set" || "$app_team" != "$lib_team" ]]; then echo "Team ID mismatch (app: $app_team, dylib: $lib_team); not submitting."; exit 1; fi
"$bundle/Contents/MacOS/JHCutStudio" >/tmp/jhcut-signed-launch.log 2>&1 & pid=$!; sleep 5
if ! kill -0 $pid 2>/dev/null; then echo "Signed app did not stay running:"; tail -5 /tmp/jhcut-signed-launch.log; exit 1; fi; kill $pid
archive="$output/JH-CUT-Studio-notarization.zip"
ditto -c -k --keepParent "$bundle" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$JHCUT_NOTARY_PROFILE" --wait
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
spctl --assess --type execute --verbose "$bundle"
# Repackage after stapling so offline Gatekeeper can validate the ticket.
ditto -c -k --keepParent "$bundle" "$output/JH-CUT-Studio.zip"
