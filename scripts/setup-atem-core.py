#!/usr/bin/env python3
"""Fetch the pinned token-library sources, without installing or building Atem."""

import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import urllib.request


def main():
    repo = Path(__file__).resolve().parent.parent
    pin = json.loads((repo / "Config/atem-core.json").read_text())
    destination = repo / "third_party/atem-core"
    marker = destination / ".setup"
    fingerprint = hashlib.sha256((repo / "Config/atem-core.json").read_bytes() +
        (repo / "Config/atem-core.Cargo.lock").read_bytes() + Path(__file__).read_bytes()).hexdigest()
    if marker.exists() and marker.read_text().strip() == fingerprint:
        return
    url = "https://codeload.github.com/Agora-Build/Atem/tar.gz/" + pin["revision"]
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != pin["archive_sha256"]:
        raise ValueError("atem-core source archive checksum mismatch")
    destination.mkdir(parents=True, exist_ok=True)
    prefixes = ("crates/atem-core/", "crates/atem-core-ffi/")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
        for member in source.getmembers():
            relative = Path(*Path(member.name).parts[1:])
            if not member.isfile() or not (str(relative).startswith(prefixes) or str(relative) == "Cargo.lock"):
                continue
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Unsafe path in atem-core archive")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as stream, target.open("wb") as output:
                shutil.copyfileobj(stream, output)
    (destination / "Cargo.toml").write_text(
        '[workspace]\nmembers = ["crates/atem-core", "crates/atem-core-ffi"]\nresolver = "2"\n'
    )
    # Consumer builds do not need Agora's upstream test-only Git dependency.
    manifest = destination / "crates/atem-core/Cargo.toml"
    manifest.write_text(manifest.read_text().split("[dev-dependencies]")[0])
    # Preserve Astation's existing zlib serialization using the shared builder.
    ffi_manifest = destination / "crates/atem-core-ffi/Cargo.toml"
    ffi_manifest.write_text(ffi_manifest.read_text() +
        '\nflate2 = { version = "1.0", default-features = false, features = ["zlib"] }\n')
    shutil.copyfile(repo / "Config/atem-core.Cargo.lock", destination / "Cargo.lock")
    marker.write_text(fingerprint + "\n")
    print("Prepared atem-core " + pin["revision"])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("atem-core setup failed: " + str(error), file=sys.stderr)
        sys.exit(1)
