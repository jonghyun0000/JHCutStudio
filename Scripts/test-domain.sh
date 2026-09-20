#!/bin/bash
set -euo pipefail
JHCUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JHCUT_BUILD="$JHCUT_ROOT/Build/domain-tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
JHCUT_XCODE="${JHCUT_XCODE:-/Applications/Xcode.app/Contents/Developer}"
JHCUT_TEST_PLATFORM="$JHCUT_XCODE/Platforms/MacOSX.platform/Developer"
JHCUT_FRAMEWORKS="$JHCUT_TEST_PLATFORM/Library/Frameworks"
JHCUT_PRIVATE_FRAMEWORKS="$JHCUT_TEST_PLATFORM/Library/PrivateFrameworks"
if [[ ! -d "$JHCUT_FRAMEWORKS/XCTest.framework" ]]; then
    echo "XCTest.framework not found. Install Xcode or set JHCUT_XCODE to its Contents/Developer directory." >&2
    exit 1
fi
mkdir -p "$JHCUT_BUILD"
JHCUT_TARGET="$(uname -m)-apple-macosx14.0"
xcrun swiftc -swift-version 5 -target "$JHCUT_TARGET" -parse-as-library -enable-testing -emit-library -emit-module -module-name JHCutCore \
    "$JHCUT_ROOT"/Domain/*.swift "$JHCUT_ROOT"/Persistence/*.swift \
    -emit-module-path "$JHCUT_BUILD/JHCutCore.swiftmodule" -o "$JHCUT_BUILD/libJHCutCore.dylib"
cat > "$JHCUT_BUILD/main.swift" <<'SWIFT'
import Foundation
import XCTest
let suite = XCTestSuite(name: "JH CUT Domain and Persistence")
for testClass in [MediaTimeTests.self, EditingTests.self, PersistenceTests.self, UpgradeEditingTests.self, SRTAndRecoveryTests.self, AdvancedCommandTests.self, CollectionAndCompatibilityTests.self, CaptionEditingTests.self, WorkspaceVolumeCollectionTests.self] {
    suite.addTest(XCTestSuite(forTestCaseClass: testClass))
}
suite.run()
guard let result = suite.testRun else { exit(2) }
print("DOMAIN_TEST_RESULT tests=\(result.executionCount) failures=\(result.totalFailureCount)")
exit(result.totalFailureCount == 0 && result.executionCount > 0 ? 0 : 1)
SWIFT
xcrun swiftc -swift-version 5 -target "$JHCUT_TARGET" -I "$JHCUT_BUILD" -L "$JHCUT_BUILD" -lJHCutCore \
    -I "$JHCUT_TEST_PLATFORM/usr/lib" -L "$JHCUT_TEST_PLATFORM/usr/lib" \
    -F "$JHCUT_FRAMEWORKS" -F "$JHCUT_PRIVATE_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$JHCUT_BUILD" \
    -Xlinker -rpath -Xlinker "$JHCUT_TEST_PLATFORM/usr/lib" \
    -Xlinker -rpath -Xlinker "$JHCUT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$JHCUT_PRIVATE_FRAMEWORKS" \
    "$JHCUT_ROOT/Tests/DomainTests.swift" "$JHCUT_ROOT/Tests/PersistenceTests.swift" "$JHCUT_ROOT/Tests/UpgradeTests.swift" "$JHCUT_BUILD/main.swift" \
    -o "$JHCUT_BUILD/JHCutDomainTests"
JHCUT_COLLECTION_TEST_ROOT="$JHCUT_BUILD" "$JHCUT_BUILD/JHCutDomainTests"
