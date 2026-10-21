#!/usr/bin/env python3
"""Consume a pinned prebuilt Apple package. Never fetch or build Atem source."""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile
import zipfile


REPO = Path(__file__).resolve().parent.parent


def check_hash(data, expected, label):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"{label}: SHA-256 mismatch")


def extract_zip(data, destination):
    """Extract only regular files/directories into a new private directory."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = set()
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            if (name.is_absolute() or ".." in name.parts or "\\" in entry.filename
                    or not name.parts or name.as_posix() in names
                    or stat.S_ISLNK(mode)
                    or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
                raise ValueError("unsafe or duplicate archive path")
            names.add(name.as_posix())
            target = destination.joinpath(*name.parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="existing GitHub artifact ZIP; otherwise download with gh")
    args = parser.parse_args()
    pin = json.loads((REPO / "Config/atem-client-apple.json").read_text())
    if args.archive:
        data = args.archive.read_bytes()
    else:
        data = subprocess.check_output([
            "gh", "api",
            f"repos/{pin['repository']}/actions/artifacts/{pin['artifact_id']}/zip",
        ])
    check_hash(data, pin["archive_sha256"], "GitHub artifact")
    with tempfile.TemporaryDirectory(prefix="astation-client-consumer-") as temporary:
        work = Path(temporary)
        payloads = work / "payloads"
        payloads.mkdir()
        extract_zip(data, payloads)
        for name, digest in pin["payload_sha256"].items():
            check_hash((payloads / name).read_bytes(), digest, name)
        source = json.loads((payloads / pin["source"]).read_text())
        if (source.get("commit") != pin["revision"] or source.get("tree_dirty") is not False
                or source.get("features") != "default (uniffi)"
                or source.get("artifact") != "apple-swiftpm"):
            raise ValueError("unexpected package source or production features")
        package = work / "package"
        package.mkdir()
        extract_zip((payloads / pin["package"]).read_bytes(), package)
        # No Package.swift or archive-supplied scripts are executed. Compile
        # the supplied wrapper and link the supplied universal static library.
        root = package / "AtemClient"
        library = root / "atem_client_ffiFFI.xcframework/macos-arm64_x86_64"
        executable = work / "consumer"
        subprocess.run([
            "swiftc", "-module-cache-path", str(work / "module-cache"),
            "-I", str(library / "Headers"), "-L", str(library),
            "-latem_client_ffi", "-framework", "Security", "-framework", "SystemConfiguration",
            str(root / "Sources/AtemClient/atem_client_ffi.swift"),
            str(REPO / "scripts/tests/atem-client-consumer/main.swift"),
            "-o", str(executable),
        ], check=True)
        fixture = REPO / "scripts/tests/atem-client-consumer/r9-vectors-pairing.json"
        fixture_bytes = fixture.read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(fixture_bytes)).encode() + b"\0" + fixture_bytes).hexdigest()
        if blob != pin["fixture"]["git_blob_sha1"]:
            raise ValueError("pairing fixture differs from the immutable reviewed blob")
        subprocess.run([str(executable), str(fixture)], check=True)
        print(f"Verified prebuilt Apple package at {pin['revision']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"atem-client consumer check failed: {error}", file=sys.stderr)
        sys.exit(1)
