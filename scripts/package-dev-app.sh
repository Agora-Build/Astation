#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/.build/debug"
app_bundle="${ASTATION_DEV_BUNDLE_DIR:-$repo_dir/.build/Astation Dev.app}"
app_executable="$app_bundle/Contents/MacOS/Astation"
bundle_id="${ASTATION_DEV_BUNDLE_ID:-build.agora.astation}"
signing_identity="${ASTATION_SIGNING_IDENTITY:--}"
profile="${ASTATION_PROVISIONING_PROFILE:-}"
entitlements=""

if [[ ! "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    printf 'Invalid development bundle identifier: %s\n' "$bundle_id" >&2
    exit 1
fi
if [[ "$signing_identity" == - && -n "$profile" || "$signing_identity" != - && -z "$profile" ]]; then
    printf 'Set both ASTATION_SIGNING_IDENTITY and ASTATION_PROVISIONING_PROFILE for provisioned signing.\n' >&2
    exit 1
fi

if [[ ! -x "$build_dir/astation" ]]; then
    printf 'Build the Swift app first: swift build\n' >&2
    exit 1
fi
running_pids="$(/usr/sbin/lsof -t -a -d txt "$app_executable" 2>/dev/null || true)"
if [[ -f "$app_executable" && -n "$running_pids" ]]; then
    printf 'Quit Astation Dev before replacing its development bundle.\n' >&2
    exit 1
fi

cleanup() {
    [[ -z "${staged_executable:-}" || ! -f "$staged_executable" ]] || rm -f -- "$staged_executable"
    [[ -z "$entitlements" || ! -f "$entitlements" ]] || rm -f -- "$entitlements"
    return 0
}
trap cleanup EXIT
if [[ -n "$profile" ]]; then
    entitlements="$(mktemp "$repo_dir/.build/dev-entitlements.XXXXXX")"
    python3 - "$profile" "$bundle_id" "$signing_identity" "$entitlements" <<'PY'
import datetime
import fnmatch
import hashlib
import plistlib
import re
import subprocess
import sys
from pathlib import Path

profile_path, bundle_id, identity, destination = sys.argv[1:]
decoded = subprocess.run(["security", "cms", "-D", "-i", profile_path], capture_output=True, check=True)
profile = plistlib.loads(decoded.stdout)
allowed = profile["Entitlements"]
profile_id = allowed["com.apple.application-identifier"]
app_id = profile_id.split(".", 1)[0] + "." + bundle_id
if not fnmatch.fnmatchcase(app_id, profile_id):
    sys.exit("The provisioning profile does not authorize this bundle identifier.")
if not any(fnmatch.fnmatchcase(app_id, group) for group in allowed.get("keychain-access-groups", [])):
    sys.exit("The provisioning profile does not authorize this app's Keychain access group.")
if profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
    sys.exit("The provisioning profile expired. Run verify-local-signing.sh to renew it.")
if re.fullmatch(r"[0-9a-fA-F]{40}", identity) and not any(
    hashlib.sha1(cert).hexdigest() == identity.lower() for cert in profile["DeveloperCertificates"]
):
    sys.exit("The provisioning profile does not authorize this signing certificate.")
entitlements = {
    "com.apple.application-identifier": app_id,
    "com.apple.developer.team-identifier": profile["TeamIdentifier"][0],
    "keychain-access-groups": [app_id],
}
if allowed.get("com.apple.security.get-task-allow"):
    entitlements["com.apple.security.get-task-allow"] = True
Path(destination).write_bytes(plistlib.dumps(entitlements))
PY
fi

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Frameworks" "$app_bundle/Contents/Resources"
staged_executable="$(mktemp "$app_bundle/Contents/MacOS/.Astation.XXXXXX")"
cp -p "$build_dir/astation" "$staged_executable"
cp "$repo_dir/Config/Info.plist" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_bundle/Contents/Info.plist"
if [[ "$bundle_id" != build.agora.astation ]]; then
    # An isolated local build must not claim the production SSO callback scheme.
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$app_bundle/Contents/Info.plist"
fi
if [[ -n "$profile" ]]; then
    cp "$profile" "$app_bundle/Contents/embedded.provisionprofile"
else
    rm -f -- "$app_bundle/Contents/embedded.provisionprofile"
fi

# A real bundle is required for signing and macOS capture-permission attribution.
for framework in "$build_dir"/*.framework; do
    [[ -d "$framework" ]] || continue
    destination="$app_bundle/Contents/Frameworks/$(basename "$framework")"
    if [[ -L "$destination" ]]; then unlink "$destination"; fi
    ditto "$framework" "$destination"
    codesign --force --sign "$signing_identity" "$destination"
done
for resource in "$build_dir"/*.bundle; do
    [[ -d "$resource" ]] || continue
    destination="$app_bundle/Contents/Resources/$(basename "$resource")"
    if [[ -L "$destination" ]]; then unlink "$destination"; fi
    ditto "$resource" "$destination"
done
# Replace atomically: a pending privacy check may still hold the old file open.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$staged_executable"
signing_args=(--force --sign "$signing_identity" --identifier "$bundle_id")
if [[ -n "$entitlements" ]]; then
    signing_args+=(--entitlements "$entitlements")
else
    # Keep the ad hoc development permission identity stable across rebuilds.
    signing_args+=(--requirements "=designated => identifier \"$bundle_id\"")
fi
codesign "${signing_args[@]}" "$staged_executable"
mv -f "$staged_executable" "$app_executable"
codesign "${signing_args[@]}" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf 'Development bundle: %s\n' "$app_bundle"
