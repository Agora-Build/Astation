#!/usr/bin/env python3
"""Verify and install the pinned prebuilt Android SDK; never build Atem source."""

import argparse
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile


REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("apple_consumer", REPO / "scripts/check-atem-client-apple.py")
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)


def check_elf(data, abi):
    expected = {"arm64-v8a": (2, 183), "armeabi-v7a": (1, 40), "x86_64": (2, 62)}
    elf_class, machine = expected[abi]
    if (len(data) < 64 or data[:4] != b"\x7fELF" or data[4:7] != bytes((elf_class, 1, 1))
            or struct.unpack_from("<HH", data, 16) != (3, machine)):
        raise ValueError(f"invalid ELF library for {abi}")
    if elf_class == 2:
        offset = struct.unpack_from("<Q", data, 32)[0]
        entry_size, count = struct.unpack_from("<HH", data, 54)
        fmt = "<IIQQQQQQ"
    else:
        offset = struct.unpack_from("<I", data, 28)[0]
        entry_size, count = struct.unpack_from("<HH", data, 42)
        fmt = "<IIIIIIII"
    if entry_size < struct.calcsize(fmt) or not count or offset + entry_size * count > len(data):
        raise ValueError(f"invalid ELF program headers for {abi}")
    loads = 0
    for index in range(count):
        fields = struct.unpack_from(fmt, data, offset + entry_size * index)
        if fields[0] != 1:
            continue
        loads += 1
        file_offset, virtual_address = fields[2:4] if elf_class == 2 else fields[1:3]
        alignment = fields[7]
        if alignment < 16384 or alignment & (alignment - 1) or (file_offset - virtual_address) % 16384:
            raise ValueError(f"{abi} is not compatible with 16 KiB memory pages")
    if not loads:
        raise ValueError(f"missing loadable ELF segments for {abi}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()
    pin = json.loads((REPO / "Config/atem-client-android.json").read_text())
    apple_pin = json.loads((REPO / "Config/atem-client-apple.json").read_text())
    if pin["revision"] != apple_pin["revision"]:
        raise ValueError("Android and Apple SDK revisions must agree")
    data = args.archive.read_bytes() if args.archive else subprocess.check_output([
        "gh", "api", f"repos/{pin['repository']}/actions/artifacts/{pin['artifact_id']}/zip"])
    consumer.check_hash(data, pin["archive_sha256"], "GitHub artifact")
    with tempfile.TemporaryDirectory(prefix="astation-android-consumer-") as temporary:
        work = Path(temporary)
        payloads = work / "payloads"
        payloads.mkdir()
        consumer.extract_zip(data, payloads)
        for name, digest in pin["payload_sha256"].items():
            consumer.check_hash((payloads / name).read_bytes(), digest, name)
        source = json.loads((payloads / pin["source"]).read_text())
        if (source.get("commit") != pin["revision"] or source.get("tree_dirty") is not False
                or source.get("artifact") != "android" or source.get("features") !=
                "android: default (uniffi), cdylib, minSdk 24, -z max-page-size=16384"):
            raise ValueError("unexpected Android package source or features")
        package = work / "package"
        package.mkdir()
        consumer.extract_zip((payloads / pin["package"]).read_bytes(), package)
        root = package / "atem-client-android"
        abis = {"arm64-v8a", "armeabi-v7a", "x86_64"}
        if {p.name for p in (root / "jniLibs").iterdir()} != abis:
            raise ValueError("unexpected SDK ABIs")
        for abi in abis:
            check_elf((root / "jniLibs" / abi / "libatem_client_ffi.so").read_bytes(), abi)
        wrapper = root / "kotlin/uniffi/atem_client_ffi/atem_client_ffi.kt"
        if "package uniffi.atem_client_ffi" not in wrapper.read_text():
            raise ValueError("unexpected Kotlin binding package")
        fixture_name = next(name for name in pin["payload_sha256"] if name.endswith("-host-work-requests-v1.json"))
        if (payloads / fixture_name).read_bytes() != (REPO / "native-remote/Tests/AstationRemoteTests/Fixtures/host-work-requests-v1.json").read_bytes():
            raise ValueError("host-work fixture differs from the reviewed package")
        if args.install:
            destination = REPO / "build/atem-client" / pin["revision"] / "atem-client-android"
            consumer.install_package(root, destination)
            print(f"Installed verified Android SDK: {destination}")
        print(f"Verified Android SDK at {pin['revision']}: all three ABIs support 16 KiB pages")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, struct.error, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"Android SDK verification failed: {error}", file=sys.stderr)
        sys.exit(1)
