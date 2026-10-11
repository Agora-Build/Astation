#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
version="$(python3 scripts/release_signing.py preflight)"
app="$repo_dir/Astation.app"
[[ -d "$app" ]] || { printf 'Create Astation.app before signing.\n' >&2; exit 1; }
signing_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/astation-release.XXXXXX")"
keychain="$signing_dir/signing.keychain-db"

cleanup() {
    set +e
    python3 - "$signing_dir" <<'PY'
import json, subprocess, sys
from pathlib import Path
saved = Path(sys.argv[1]) / 'keychains.json'
if saved.exists():
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *json.loads(saved.read_text())], check=True)
PY
    [[ ! -f "$keychain" ]] || security delete-keychain "$keychain"
    rm -rf -- "$signing_dir"
}
trap cleanup EXIT
python3 scripts/release_signing.py prepare "$signing_dir"
python3 - "$signing_dir/keychains.json" <<'PY'
import json, shlex, subprocess, sys
from pathlib import Path
result = subprocess.run(['security', 'list-keychains', '-d', 'user'], capture_output=True, text=True, check=True)
Path(sys.argv[1]).write_text(json.dumps(shlex.split(result.stdout)))
PY
keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificates.p12" -k "$keychain" \
    -P "$ASTATION_SIGNING_CERTIFICATES_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/pkgbuild -T /usr/bin/productsign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$keychain" >/dev/null
python3 - "$keychain" "$signing_dir/keychains.json" <<'PY'
import json, subprocess, sys
from pathlib import Path
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', sys.argv[1],
                *json.loads(Path(sys.argv[2]).read_text())], check=True)
PY

cp "$signing_dir/app.provisionprofile" "$app/Contents/embedded.provisionprofile"
sign_code() {
    codesign --force --timestamp --options runtime --keychain "$keychain" \
        --sign "$ASTATION_APPLICATION_IDENTITY" "$@"
}
# Sign nested code before sealing the containing frameworks and app.
while IFS= read -r -d '' library; do sign_code "$library"; done \
    < <(find "$app/Contents/Frameworks" -type f -name '*.dylib' -print0)
while IFS= read -r -d '' framework; do sign_code "$framework"; done \
    < <(find "$app/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
sign_code --identifier build.agora.astation --entitlements "$signing_dir/entitlements.plist" "$app"
codesign --verify --deep --strict "$app"
python3 scripts/release_signing.py verify-app "$app" "$signing_dir"

# Probe the real protected Keychain without accessing user credentials or needing Touch ID.
probe="$signing_dir/Keychain Probe.app"
mkdir -p "$probe/Contents/MacOS"
cp "$app/Contents/Info.plist" "$probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable KeychainProbe' "$probe/Contents/Info.plist"
cp "$signing_dir/app.provisionprofile" "$probe/Contents/embedded.provisionprofile"
xcrun swiftc -parse-as-library Config/LocalSigningProbe.swift -o "$probe/Contents/MacOS/KeychainProbe"
sign_code --identifier build.agora.astation --entitlements "$signing_dir/entitlements.plist" "$probe"
env -i PATH=/usr/bin:/bin "$probe/Contents/MacOS/KeychainProbe"

notarize() {
    local payload="$1" report="$2"
    xcrun notarytool submit "$payload" --key "$signing_dir/notary.p8" \
        --key-id "$ASTATION_NOTARY_KEY_ID" --issuer "$ASTATION_NOTARY_ISSUER_ID" \
        --wait --timeout 30m --output-format json > "$report"
    python3 - "$report" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
print('Notarization:', result.get('status'), 'submission', result.get('id'))
if result.get('status') != 'Accepted':
    sys.exit('Apple did not accept this release for notarization.')
PY
}
ditto -c -k --sequesterRsrc --keepParent "$app" "$signing_dir/app.zip"
notarize "$signing_dir/app.zip" "$signing_dir/app-notarization.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"

mkdir -p "$signing_dir/pkg-root/Applications" "$repo_dir/dist"
ditto "$app" "$signing_dir/pkg-root/Applications/Astation.app"
package="$repo_dir/dist/Astation-v$version-mac-arm64.pkg"
pkgbuild --root "$signing_dir/pkg-root" --identifier build.agora.astation \
    --version "$version" --install-location / --sign "$ASTATION_INSTALLER_IDENTITY" \
    --keychain "$keychain" --timestamp "$package"
pkgutil --check-signature "$package" > "$signing_dir/pkg-signature.txt"
grep -E "Developer ID Installer:.*\($ASTATION_SIGNING_TEAM_ID\)" "$signing_dir/pkg-signature.txt" >/dev/null \
    || { printf 'Installer is not signed by the expected Developer ID team.\n' >&2; exit 1; }
notarize "$package" "$signing_dir/pkg-notarization.json"
xcrun stapler staple "$package"
xcrun stapler validate "$package"
spctl --assess --type install --verbose "$package"
tar -czf "$repo_dir/dist/Astation-v$version-mac-arm64.tar.gz" -C "$repo_dir" Astation.app
(
    cd "$repo_dir/dist"
    shasum -a 256 "Astation-v$version-mac-arm64.pkg" "Astation-v$version-mac-arm64.tar.gz" \
        > "Astation-v$version-mac-arm64.SHA256SUMS"
)
printf 'Signed and notarized Astation v%s artifacts are in dist/.\n' "$version"
