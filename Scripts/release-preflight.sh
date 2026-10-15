#!/bin/bash
# Release preflight WITHOUT credentials: verifies everything the Developer ID / notarization
# procedure (Scripts/package-release.sh) depends on, using an ad-hoc signed COPY of the bundle.
# It does not sign with a real identity, does not submit to Apple and never asks for passwords.
# Usage: Scripts/release-preflight.sh [bundle]
set -uo pipefail
cd "$(dirname "$0")/.."
bundle="${1:-Build/JH CUT Studio.app}"
mkdir -p Artifacts/ReleasePreflight
work="$(mktemp -d "$PWD/Artifacts/ReleasePreflight/run.XXXXXX")"
owned_hardened_pid=""
owned_fresh_pid=""
cleanup() {
  # Restrict termination to PIDs still reported as live jobs of this shell.
  local cleanup_pid
  for cleanup_pid in "$owned_hardened_pid" "$owned_fresh_pid"; do
    if [[ -n "$cleanup_pid" ]]; then
      local live_child
      for live_child in $(jobs -pr); do
        [[ "$live_child" == "$cleanup_pid" ]] && kill "$cleanup_pid" 2>/dev/null || true
      done
      wait "$cleanup_pid" 2>/dev/null || true
    fi
  done
  echo "PREFLIGHT evidence: $work"
}
trap cleanup EXIT
pass=0; fail=0
ok() { echo "PASS $1 ${2:-}"; pass=$((pass + 1)); }
bad() { echo "FAIL $1 ${2:-}"; fail=$((fail + 1)); }
note() { echo "NOTE $1"; }

# 1. Tools the real procedure calls.
for tool in codesign spctl ditto; do command -v "$tool" >/dev/null && ok "tool $tool" || bad "tool $tool missing"; done
for tool in notarytool stapler; do xcrun --find "$tool" >/dev/null 2>&1 && ok "tool $tool" "$(xcrun --find $tool)" || bad "tool $tool missing (install Xcode or Command Line Tools)"; done

# 2. Bundle contents and versions.
plist="$bundle/Contents/Info.plist"
[[ -f "$plist" ]] || { bad "bundle" "$bundle has no Info.plist"; echo "PREFLIGHT pass=$pass fail=$fail"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist"); build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist"); minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "version" "$version ($build) $identifier · macOS $minimum+" || bad "version" "$version"
source_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
[[ "$source_version" == "$version" ]] && ok "bundle version matches Resources/Info.plist" || bad "bundle version $version differs from Resources/Info.plist $source_version (rebuild)"
grep -q "JH CUT Studio ${version%.*}" README.md && ok "README names version ${version%.*}" || bad "README does not name version ${version%.*}"
grep -q "$version" docs/STATUS.md && ok "docs/STATUS.md names $version" || bad "docs/STATUS.md does not name $version"
[[ -x "$bundle/Contents/Resources/Whisper/whisper-cli" ]] && ok "whisper runtime in bundle" || bad "whisper runtime missing"
[[ -f "$bundle/Contents/Frameworks/libJHCutCore.dylib" ]] && ok "core library in bundle" || bad "core library missing"
while IFS='|' read -r notice_source notice_bundle; do
  if [[ -s "$bundle/Contents/Resources/$notice_bundle" ]] && cmp -s "$notice_source" "$bundle/Contents/Resources/$notice_bundle"; then
    ok "complete license notice $notice_bundle"
  else
    bad "missing or stale license notice $notice_bundle" "rebuild before distribution"
  fi
done <<'NOTICES'
LICENSE|Legal/LICENSE.txt
THIRD_PARTY_NOTICES.md|Legal/THIRD_PARTY_NOTICES.md
Resources/Brand/README.md|Legal/BRAND.md
Resources/Whisper/THIRD-PARTY-NOTICES.txt|Whisper/THIRD-PARTY-NOTICES.txt
Resources/Library/CREDITS.md|Library/CREDITS.md
NOTICES
if find "$bundle" -name 'ggml-*.bin' | grep -q .; then bad "model file bundled" "models are installed by the user, not shipped"; else ok "no speech model inside the bundle (installed with consent)"; fi

# 3. Every Mach-O must be covered by package-release.sh, signed inside-out.
machos=(); while IFS= read -r -d '' f; do file -b "$f" | grep -q 'Mach-O' && machos+=("${f#$bundle/}"); done < <(find "$bundle" -type f -print0)
ok "Mach-O files found" "${#machos[@]}: ${machos[*]}"
for m in "${machos[@]}"; do
  [[ "$m" == "Contents/MacOS/"* ]] && continue   # signed as part of the bundle
  grep -qF "${m#Contents/}" Scripts/package-release.sh && ok "release script signs $m" || bad "release script does not sign $m"
done

# 4. Ad-hoc hardened-runtime signature on a copy, inner code first, then strict verification.
copy="$work/JH CUT Studio.app"; ditto "$bundle" "$copy"
signed=1
for m in "${machos[@]}"; do [[ "$m" == "Contents/MacOS/"* ]] || codesign --force --options runtime --sign - "$copy/$m" 2>"$work/sign.log" || signed=0; done
codesign --force --options runtime --sign - "$copy" 2>>"$work/sign.log" || signed=0
[[ $signed == 1 ]] && ok "hardened-runtime signing of every component" || bad "signing failed" "$(cat "$work/sign.log")"
codesign --verify --deep --strict "$copy" 2>"$work/verify.log" && ok "codesign --verify --deep --strict" || bad "strict verification" "$(cat "$work/verify.log")"
codesign -dv "$copy" 2>&1 | grep -q 'flags=0x10002(adhoc,runtime)\|runtime' && ok "hardened runtime flag present" || bad "hardened runtime flag missing"

# 5. The signed copy still runs its recogniser (library loading under hardened runtime).
"$copy/Contents/Resources/Whisper/whisper-cli" --help >/dev/null 2>&1; code=$?
[[ $code == 0 || $code == 1 ]] && ok "signed whisper-cli starts" "exit $code" || bad "signed whisper-cli failed to start" "exit $code"

# Measured: under hardened runtime, library validation refuses libJHCutCore.dylib in an ad-hoc copy
# ("mapping process and mapped file have different Team IDs") because ad-hoc code has no Team ID.
# A Developer ID signature gives the app and the dylib the same Team ID; that part can only be
# confirmed with a real certificate (package-release.sh checks it before submitting).
"$copy/Contents/MacOS/JHCutStudio" >"$work/hardened.log" 2>&1 & owned_hardened_pid=$!; sleep 2; kill "$owned_hardened_pid" 2>/dev/null; wait "$owned_hardened_pid" 2>/dev/null; owned_hardened_pid=""
grep -q "different Team IDs" "$work/hardened.log" && note "ad-hoc hardened copy cannot load its dylib (no Team ID) — expected; requires one Developer ID for app and dylib"

# 6. Clean-install simulation: launch an unmodified copy with an EMPTY home (no settings, no model,
#    no Application Support). CFFIXED_USER_HOME redirects Foundation's user directories.
fresh="$work/fresh/JH CUT Studio.app"; mkdir -p "$work/fresh"; ditto "$bundle" "$fresh"
preflight_home="$work/fresh-home"; mkdir -p "$preflight_home"
# A separate bundle identifier prevents cfprefsd sharing the real app preference domain.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier.preflight.$(uuidgen | tr -d '-')" "$fresh/Contents/Info.plist" || { bad "private preference domain"; exit 1; }
codesign --force --sign - "$fresh" >"$work/fresh-sign.log" 2>&1 || { bad "fresh copy signing"; exit 1; }
real_support="$HOME/Library/Application Support/JHCutStudio"
inventory_roots=("support=$real_support" "preferences=$HOME/Library/Preferences/$identifier.plist")
for preferences_path in "$HOME/Library/Preferences/ByHost/$identifier."*.plist; do
  [[ -e "$preferences_path" ]] && inventory_roots+=("$(basename "$preferences_path")=$preferences_path")
done
python3 -B Scripts/release_inventory.py "$work/user-before.json" "${inventory_roots[@]}" || { bad "user-data inventory before launch"; exit 1; }
CFFIXED_USER_HOME="$preflight_home" "$fresh/Contents/MacOS/JHCutStudio" >"$work/launch.log" 2>&1 &
owned_fresh_pid=$!; sleep 8
if kill -0 "$owned_fresh_pid" 2>/dev/null; then ok "fresh-home launch stays running for 8 s"; kill "$owned_fresh_pid"; wait "$owned_fresh_pid" 2>/dev/null; else bad "fresh-home launch exited" "$(tail -5 "$work/launch.log")"; wait "$owned_fresh_pid" 2>/dev/null; fi
owned_fresh_pid=""
# Re-enumerate ByHost files so newly created real preference files cannot escape detection.
inventory_roots=("support=$real_support" "preferences=$HOME/Library/Preferences/$identifier.plist")
for preferences_path in "$HOME/Library/Preferences/ByHost/$identifier."*.plist; do
  [[ -e "$preferences_path" ]] && inventory_roots+=("$(basename "$preferences_path")=$preferences_path")
done
if python3 -B Scripts/release_inventory.py "$work/user-after.json" "${inventory_roots[@]}" && cmp -s "$work/user-before.json" "$work/user-after.json"; then
  ok "real Application Support and preference contents/identities unchanged"
else
  bad "real user-data inventory changed or unverifiable"
fi
note "Private-home/private-identifier launch is an 8-second smoke check, not another-user or complete clean-install acceptance."
[[ ! -e "$preflight_home/Library/Application Support/JHCutStudio/Models/ggml-base.bin" ]] && ok "no model downloaded on first launch" || bad "a model appeared without consent"

# 7. What Gatekeeper says about an ad-hoc build (expected: rejected until Developer ID + notarization).
if spctl --assess --type execute "$copy" 2>/dev/null; then note "Gatekeeper accepted the ad-hoc copy (unexpected on a default system)"; else note "Gatekeeper rejects the ad-hoc copy as expected; distribution needs Scripts/package-release.sh with a Developer ID identity and a notarytool profile."; fi
echo "PREFLIGHT pass=$pass fail=$fail"
exit $fail
