#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/run-dev.sh [--force-build] [--build-only]

  --force-build  Recompile the C++ core and clean/rebuild the Swift app, then run.
  --build-only   Build both components without launching Astation.
  -h, --help     Show this help.

Without options, incrementally build Swift, then run. Build C++ if missing.
Downloaded dependencies and SDKs are retained during a forced rebuild.

Build prerequisites: macOS 14+, Xcode Command Line Tools, CMake (brew install cmake).
Optional environment: CMAKE=/path/to/cmake, AGORA_SDK_DIR=/path/to/sdk,
                      AGORA_SKIP_DOWNLOAD=ON (use an existing SDK).
EOF
}

force_build=false
build_only=false
for argument in "$@"; do
    case "$argument" in
        --force-build) force_build=true ;;
        --build-only) build_only=true ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
binary="$repo_dir/.build/debug/astation"

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The Astation menubar app requires macOS 14 or later.\n' >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    printf 'Swift not found. Install Xcode Command Line Tools: xcode-select --install\n' >&2
    exit 1
fi

if [[ "$force_build" == true || "$build_only" == true || ! -f "$repo_dir/build/libastation_core.a" ]]; then
    cmake_bin="${CMAKE:-cmake}"
    if ! command -v "$cmake_bin" >/dev/null 2>&1; then
        printf 'CMake not found. Install it with: brew install cmake\n' >&2
        exit 1
    fi
    configure_args=(
        -S "$repo_dir" -B "$repo_dir/build"
        -DBUILD_TESTING=ON
        -DCMAKE_BUILD_TYPE=Debug
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    )
    # Preserve an existing CMake SDK configuration unless explicitly overridden.
    if [[ -n "${AGORA_SDK_DIR:-}" ]]; then
        configure_args+=("-DAGORA_SDK_DIR=$AGORA_SDK_DIR")
    fi
    if [[ -n "${AGORA_SKIP_DOWNLOAD:-}" ]]; then
        configure_args+=("-DAGORA_SKIP_DOWNLOAD=$AGORA_SKIP_DOWNLOAD")
    fi

    printf 'Configuring C++ core...\n'
    "$cmake_bin" "${configure_args[@]}"
    build_args=(--build "$repo_dir/build" --parallel "$(sysctl -n hw.ncpu)")
    if [[ "$force_build" == true ]]; then
        build_args+=(--clean-first)
    fi
    printf 'Building C++ core...\n'
    "$cmake_bin" "${build_args[@]}"

fi

if [[ "$force_build" == true ]]; then
    printf 'Cleaning Swift build products...\n'
    swift package clean
fi
printf 'Building Swift app...\n'
swift build --configuration debug --product astation

if [[ "$build_only" == true ]]; then
    printf 'Build complete: %s\n' "$binary"
    exit 0
fi

printf 'Starting Astation (menu bar app). Press Ctrl+C to stop.\n'
exec "$binary"
