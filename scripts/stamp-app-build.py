#!/usr/bin/env python3
"""Record immutable build metadata before the app bundle is signed."""

import argparse
import os
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=Path)
    parser.add_argument("--version", help="Release version; otherwise describe the local Git revision")
    args = parser.parse_args()
    info = plistlib.loads(args.plist.read_bytes())
    if args.version:
        info["CFBundleShortVersionString"] = args.version
        info["CFBundleVersion"] = args.version
        version = args.version
    else:
        try:
            result = subprocess.run(
                ["git", "describe", "--tags", "--match", "v[0-9]*", "--always", "--dirty"],
                cwd=Path(__file__).resolve().parent.parent,
                capture_output=True, text=True, check=True,
            )
            version = result.stdout.strip().removeprefix("v")
        except (FileNotFoundError, subprocess.CalledProcessError):
            version = "Development"
    info["AstationBuildVersion"] = version
    account_keys = {
        "ASTATION_ACCOUNT_CLIENT_ID": "AstationAccountClientID",
        "ASTATION_ACCOUNT_RESOURCE": "AstationAccountResource",
        "ASTATION_ACCOUNT_SCOPE": "AstationAccountScope",
    }
    if any(os.environ.get(key) for key in account_keys):
        if not all(os.environ.get(key) for key in account_keys):
            parser.error("Set all registered Astation account client, resource and scope values together.")
        for key, plist_key in account_keys.items():
            info[plist_key] = os.environ[key]
        info["AstationAccountIssuer"] = os.environ.get("ASTATION_ACCOUNT_ISSUER", "https://auth.agora.build")
    info["AstationBuildTimestamp"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    args.plist.write_bytes(plistlib.dumps(info))


if __name__ == "__main__":
    main()
