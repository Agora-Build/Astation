#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[A-Z0-9]{10}$ ]]; then
    printf 'Usage: bash scripts/verify-local-signing.sh PERSONAL_TEAM_ID [XCTest-filter]\n' >&2
    exit 2
fi

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
team_id="$1"
test_filter="${2:-All}"
bundle_id="build.agora.astation.local.$(printf '%s' "$team_id" | tr '[:upper:]' '[:lower:]')"
signing_dir="$repo_dir/.build/local-signing/$team_id"
developer_dir="$(xcode-select -p)"
platform_dir="$developer_dir/Platforms/MacOSX.platform/Developer"
probe_bundle="$signing_dir/Build/Products/Debug/AstationLocalSigning.app"
app_bundle="$repo_dir/.build/Astation Local.app"
test_host="$signing_dir/Astation Local Tests.app"
mkdir -p "$signing_dir"

printf 'Provisioning isolated local bundle %s for team %s...\n' "$bundle_id" "$team_id"
xcodebuild -quiet -project "$repo_dir/Config/LocalSigning.xcodeproj" \
    -scheme AstationLocalSigning -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$signing_dir" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$team_id" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" build
env -i PATH=/usr/bin:/bin "$probe_bundle/Contents/MacOS/AstationLocalSigning"

# Reuse exactly the identity and entitlements that Xcode successfully provisioned.
codesign -d --extract-certificates="$signing_dir/certificate-" "$probe_bundle"
identity="$(shasum -a 1 "$signing_dir/certificate-0" | awk '{print $1}')"
entitlements="$signing_dir/Local.entitlements"
codesign -d --entitlements - --xml "$probe_bundle" > "$entitlements"
profile="$probe_bundle/Contents/embedded.provisionprofile"

if [[ ! -f "$repo_dir/build/libastation_core.a" ]]; then
    printf 'Build the C++ core first: bash scripts/run-dev.sh --build-only\n' >&2
    exit 1
fi
swift build --build-tests
ASTATION_DEV_BUNDLE_DIR="$app_bundle" ASTATION_DEV_BUNDLE_ID="$bundle_id" \
    ASTATION_SIGNING_IDENTITY="$identity" ASTATION_PROVISIONING_PROFILE="$profile" \
    bash "$repo_dir/scripts/package-dev-app.sh"
env -i PATH=/usr/bin:/bin "$app_bundle/Contents/MacOS/Astation" --bundled-resources-check

# Entitlements belong to the test process, not its dynamically loaded test bundle.
# Wrap a copy of Xcode's driver; the installed Xcode executable is never modified.
ditto "$probe_bundle" "$test_host"
cp "$(xcrun --find xctest)" "$test_host/Contents/MacOS/AstationLocalSigning"
codesign --force --sign "$identity" --entitlements "$entitlements" "$test_host"
codesign --verify --deep --strict "$test_host"
bin_dir="$(swift build --show-bin-path)"
test_bundle="$bin_dir/AstationTests.xctest"
if [[ ! -d "$test_bundle" ]]; then test_bundle="$bin_dir/AstationPackageTests.xctest"; fi
if [[ ! -d "$test_bundle" ]]; then
    printf 'Cannot find the built Astation XCTest bundle in %s.\n' "$bin_dir" >&2
    exit 1
fi

# Xcode's driver dumps its environment on some errors. Pass only test necessities.
env -i PATH=/usr/bin:/bin ASTATION_REQUIRE_KEYCHAIN_TESTS=1 \
    DYLD_FRAMEWORK_PATH="$platform_dir/Library/Frameworks" \
    DYLD_LIBRARY_PATH="$platform_dir/usr/lib" \
    "$test_host/Contents/MacOS/AstationLocalSigning" -XCTest "$test_filter" "$test_bundle" 2>&1 \
    | tee "$signing_dir/tests.log"
if ! rg -q 'Executed [1-9][0-9]* tests?' "$signing_dir/tests.log"; then
    printf 'The requested filter selected no tests.\n' >&2
    exit 1
fi
printf 'Signed local app: %s\n' "$app_bundle"
