#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/.build/debug"
app_bundle="${ASTATION_DEV_BUNDLE_DIR:-$repo_dir/.build/Astation Dev.app}"
app_executable="$app_bundle/Contents/MacOS/Astation"

if [[ ! -x "$build_dir/astation" ]]; then
    printf 'Build the Swift app first: swift build\n' >&2
    exit 1
fi
running_pids="$(/usr/sbin/lsof -t -a -d txt "$app_executable" 2>/dev/null || true)"
if [[ -f "$app_executable" && -n "$running_pids" ]]; then
    printf 'Quit Astation Dev before replacing its development bundle.\n' >&2
    exit 1
fi

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Frameworks" "$app_bundle/Contents/Resources"
staged_executable="$(mktemp "$app_bundle/Contents/MacOS/.Astation.XXXXXX")"
trap '[[ ! -f "$staged_executable" ]] || rm -f -- "$staged_executable"' EXIT
cp -p "$build_dir/astation" "$staged_executable"
cp "$repo_dir/Config/Info.plist" "$app_bundle/Contents/Info.plist"

# A real bundle is required for signing and macOS capture-permission attribution.
for framework in "$build_dir"/*.framework; do
    [[ -d "$framework" ]] || continue
    destination="$app_bundle/Contents/Frameworks/$(basename "$framework")"
    if [[ -L "$destination" ]]; then unlink "$destination"; fi
    ditto "$framework" "$destination"
    codesign --force --sign - "$destination"
done
for resource in "$build_dir"/*.bundle; do
    [[ -d "$resource" ]] || continue
    destination="$app_bundle/Contents/Resources/$(basename "$resource")"
    if [[ -L "$destination" ]]; then unlink "$destination"; fi
    ditto "$resource" "$destination"
done
# Replace atomically: a pending privacy check may still hold the old file open.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$staged_executable"
codesign --force --sign - --identifier build.agora.astation "$staged_executable"
mv -f "$staged_executable" "$app_executable"
codesign --force --sign - --identifier build.agora.astation "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf 'Development bundle: %s\n' "$app_bundle"
