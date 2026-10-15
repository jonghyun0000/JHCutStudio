#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source_bundle="${JHCUT_RELEASE_BUNDLE:-Build/JH CUT Studio.app}"
output="${JHCUT_RELEASE_DIRECTORY:-Build/Distribution}"
# Resolve both paths before creating anything; output inside the input bundle would mutate it.
python3 -B - "$source_bundle" "$output" <<'PYGUARD'
import sys
from pathlib import Path
source, output = (Path(x).resolve() for x in sys.argv[1:])
if not source.is_dir() or source == output or source in output.parents:
    raise SystemExit("Input app must exist and release output must be outside it")
PYGUARD
mkdir -p "$output"
# Every invocation reserves a new directory; the source app and previous releases are immutable inputs.
release_work="$(mktemp -d "$output/release.XXXXXX")"
source_bundle="$(cd "$(dirname "$source_bundle")" && pwd)/$(basename "$source_bundle")"
python3 -B Scripts/release_inventory.py "$release_work/source-before.json" "bundle=$source_bundle"
bundle="$release_work/JH CUT Studio.app"
owned_launch_pid=""
finalize_release() {
  local result="${1:-1}"
  if [[ -n "$owned_launch_pid" ]]; then
    local child
    for child in $(jobs -pr); do
      [[ "$child" == "$owned_launch_pid" ]] && kill "$owned_launch_pid" 2>/dev/null || true
    done
    wait "$owned_launch_pid" 2>/dev/null || true
  fi
  if ! python3 -B Scripts/release_inventory.py "$release_work/source-after.json" "bundle=$source_bundle" || ! cmp -s "$release_work/source-before.json" "$release_work/source-after.json"; then
    echo "FAIL source bundle changed or cannot be verified; retained evidence: $release_work" >&2
    result=1
  fi
  printf '%s\n' "$result" >"$release_work/exit-status.txt"
  echo "Release evidence: $release_work (exit $result)"
  exit "$result"
}
trap 'finalize_release "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Validate numeric identity, complete notices and any supplied exact frozen-run binding.
metadata_args=(--bundle "$source_bundle" --notice-root "$PWD")
if [[ -n "${JHCUT_RELEASE_VERIFICATION_INDEX:-}" ]]; then
  metadata_args+=(--verification-index "$JHCUT_RELEASE_VERIFICATION_INDEX")
fi
python3 -B Scripts/release_metadata.py "${metadata_args[@]}" >"$release_work/package-input.json"
release_stem="$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["app"]["stem"])' "$release_work/package-input.json")"
ditto "$source_bundle" "$bundle"
# Prove a complete content copy before either local ZIP preparation or signing.
python3 -B Scripts/release_metadata.py "${metadata_args[@]}" --packaged-bundle "$bundle" >"$release_work/copy-validation.json"
# Local reviewable preparation only: no signing, app launch, credentials, or Apple submission.
if [[ "${JHCUT_PACKAGE_PREPARE_ONLY:-0}" == 1 ]]; then
  python3 -B Scripts/release_metadata.py "${metadata_args[@]}" --packaged-bundle "$bundle" --output "$release_work" --mode review-only
  echo "Prepared isolated REVIEW-ONLY ZIP, checksums, manifest and draft notes; no signing, app launch or Apple submission."
  exit 0
fi
if [[ -z "${JHCUT_RELEASE_VERIFICATION_INDEX:-}" ]]; then
  echo "A matching passed verification-index.json is required before signing or submission; no built-source tag is inferred from HEAD." >&2
  exit 1
fi
if [[ -z "${JHCUT_SIGN_IDENTITY:-}" || -z "${JHCUT_NOTARY_PROFILE:-}" ]]; then
  echo "Developer ID Application identity and a configured notarytool profile are required; nothing signed or submitted." >&2
  exit 1
fi
# Refuse to sign or submit a copy that fails the credential-free checks.
bash Scripts/release-preflight.sh "$bundle" || { echo "Preflight failed; nothing was signed or submitted."; exit 1; }
# Explicit invocation with supplied identities only; no automatic credential lookup or submission on build.
codesign --force --options runtime --timestamp --sign "$JHCUT_SIGN_IDENTITY" "$bundle/Contents/Resources/Whisper/whisper-cli"
codesign --force --options runtime --timestamp --sign "$JHCUT_SIGN_IDENTITY" "$bundle/Contents/Frameworks/libJHCutCore.dylib"
codesign --force --options runtime --timestamp --sign "$JHCUT_SIGN_IDENTITY" "$bundle"
codesign --verify --deep --strict "$bundle"
# Hardened runtime library validation needs the app and the dylib to carry the SAME Team ID.
app_team=$(codesign -dv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p'); lib_team=$(codesign -dv "$bundle/Contents/Frameworks/libJHCutCore.dylib" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ -z "$app_team" || "$app_team" == "not set" || "$app_team" != "$lib_team" ]]; then echo "Team ID mismatch (app: $app_team, dylib: $lib_team); not submitting."; exit 1; fi
# Smoke launch uses a private home; full native install acceptance remains separate.
signed_home="$release_work/signed-home"; mkdir -p "$signed_home"
CFFIXED_USER_HOME="$signed_home" "$bundle/Contents/MacOS/JHCutStudio" >"$release_work/signed-launch.log" 2>&1 & owned_launch_pid=$!; sleep 5
if ! kill -0 "$owned_launch_pid" 2>/dev/null; then echo "Signed app did not stay running:"; tail -5 "$release_work/signed-launch.log"; exit 1; fi
kill "$owned_launch_pid"; wait "$owned_launch_pid" 2>/dev/null || true; owned_launch_pid=""
archive="$release_work/${release_stem}-notarization-submission.zip"
ditto -c -k --keepParent "$bundle" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$JHCUT_NOTARY_PROFILE" --wait --output-format json >"$release_work/notary-result.json"
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
spctl --assess --type execute --verbose "$bundle"
# Repackage after stapling so offline Gatekeeper can validate the ticket.
python3 -B Scripts/release_metadata.py "${metadata_args[@]}" --packaged-bundle "$bundle" --output "$release_work" --mode notarized --notary-result "$release_work/notary-result.json"
