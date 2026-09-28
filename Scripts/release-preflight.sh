#!/bin/bash
# Release preflight WITHOUT credentials: verifies everything the Developer ID / notarization
# procedure (Scripts/package-release.sh) depends on, using an ad-hoc signed COPY of the bundle.
# It does not sign with a real identity, does not submit to Apple and never asks for passwords.
# Usage: Scripts/release-preflight.sh [bundle]
set -uo pipefail
cd "$(dirname "$0")/.."
bundle="${1:-Build/JH CUT Studio.app}"
work="$(mktemp -d "${TMPDIR:-/tmp}/jhcut-preflight.XXXXXX")"
trap 'pkill -f "$work/" 2>/dev/null; rm -rf "$work"' EXIT
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
"$copy/Contents/MacOS/JHCutStudio" >"$work/hardened.log" 2>&1 & hp=$!; sleep 2; kill $hp 2>/dev/null; wait $hp 2>/dev/null
grep -q "different Team IDs" "$work/hardened.log" && note "ad-hoc hardened copy cannot load its dylib (no Team ID) — expected; requires one Developer ID for app and dylib"

# 6. Clean-install simulation: launch an unmodified copy with an EMPTY home (no settings, no model,
#    no Application Support). CFFIXED_USER_HOME redirects Foundation's user directories.
fresh="$work/fresh/JH CUT Studio.app"; mkdir -p "$work/fresh"; ditto "$bundle" "$fresh"
home="$work/fresh-home"; mkdir -p "$home"
real_support="$HOME/Library/Application Support/JHCutStudio"; before=$(stat -f %m "$real_support" 2>/dev/null || echo none)
CFFIXED_USER_HOME="$home" "$fresh/Contents/MacOS/JHCutStudio" >"$work/launch.log" 2>&1 &
pid=$!; sleep 8
if kill -0 $pid 2>/dev/null; then ok "fresh-home launch stays running for 8 s"; kill $pid; wait $pid 2>/dev/null; else bad "fresh-home launch exited" "$(tail -5 "$work/launch.log")"; fi
after=$(stat -f %m "$real_support" 2>/dev/null || echo none)
[[ "$before" == "$after" ]] && ok "real Application Support untouched by the fresh-home launch" || bad "real Application Support changed"
[[ ! -e "$home/Library/Application Support/JHCutStudio/Models/ggml-base.bin" ]] && ok "no model downloaded on first launch" || bad "a model appeared without consent"

# 7. What Gatekeeper says about an ad-hoc build (expected: rejected until Developer ID + notarization).
if spctl --assess --type execute "$copy" 2>/dev/null; then note "Gatekeeper accepted the ad-hoc copy (unexpected on a default system)"; else note "Gatekeeper rejects the ad-hoc copy as expected; distribution needs Scripts/package-release.sh with a Developer ID identity and a notarytool profile."; fi
echo "PREFLIGHT pass=$pass fail=$fail"
exit $fail
