#!/usr/bin/env python3
"""Fetch pinned terminal assets, or verify them without network access."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "Config/terminal-assets.json"
DEST = ROOT / "Sources/Menubar/Resources/RemoteTerminal"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unicode_browser(provider, table):
    # Keep the host provider unchanged inside a browser-safe CommonJS wrapper.
    return ("(() => {\nconst widths = " + table.decode().strip() + ";\n"
            "const require = name => {\n"
            "  if (name !== './unicode-width-0.1.14.json') throw new Error('Unknown module');\n"
            "  return widths;\n};\nconst module = { exports: {} };\n"
            + provider.decode() + "\nwindow.AtemUnicode = module.exports.AtemUnicode;\n})();\n").encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    if args.verify:
        expected = lock.get("asset_sha256", {})
        if not expected:
            raise SystemExit("Missing terminal asset hashes")
        for name, checksum in expected.items():
            if digest((DEST / name).read_bytes()) != checksum:
                raise SystemExit("Terminal asset mismatch: " + name)
        browser = unicode_browser((DEST / "atem-unicode.cjs").read_bytes(),
                                  (DEST / "unicode-width-0.1.14.json").read_bytes())
        if browser != (DEST / "atem-unicode.js").read_bytes():
            raise SystemExit("Unicode browser wrapper differs from the host provider")
        print("Verified " + str(len(expected)) + " pinned terminal assets")
        return

    assets = {}
    for package in lock["packages"]:
        archive = urllib.request.urlopen(package["url"], timeout=30).read()
        actual = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
        if actual != package["integrity"]:
            raise SystemExit("Archive integrity mismatch: " + package["name"])
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
            for source, target in package["files"].items():
                member = tar.extractfile(source)
                if member is None:
                    raise SystemExit("Missing asset: " + source)
                assets[target] = member.read()
    base = "https://raw.githubusercontent.com/Agora-Build/Atem/" + lock["atem_commit"] + "/"
    for name, checksum in lock["atem_assets"].items():
        data = urllib.request.urlopen(base + "assets/terminal/" + name, timeout=30).read()
        if digest(data) != checksum:
            raise SystemExit("Host asset mismatch: " + name)
        assets[name] = data
    assets["atem-unicode.js"] = unicode_browser(assets["atem-unicode.cjs"],
                                              assets["unicode-width-0.1.14.json"])
    hashes = {name: digest(data) for name, data in sorted(assets.items())}
    if lock.get("asset_sha256") and lock["asset_sha256"] != hashes:
        raise SystemExit("Downloaded assets differ from checked-in hashes")
    DEST.mkdir(parents=True, exist_ok=True)
    for name, data in assets.items():
        (DEST / name).write_bytes(data)
    lock["asset_sha256"] = hashes
    LOCK.write_text(json.dumps(lock, indent=2) + "\n")
    print("Installed " + str(len(assets)) + " pinned terminal assets")


if __name__ == "__main__":
    main()
