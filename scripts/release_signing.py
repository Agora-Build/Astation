#!/usr/bin/env python3
"""Validate public release inputs without printing signing credentials."""

import base64
import datetime
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


BUNDLE_ID = "build.agora.astation"
REQUIRED = (
    "ASTATION_SIGNING_TEAM_ID",
    "ASTATION_APPLICATION_IDENTITY",
    "ASTATION_INSTALLER_IDENTITY",
    "ASTATION_SIGNING_CERTIFICATES_BASE64",
    "ASTATION_SIGNING_CERTIFICATES_PASSWORD",
    "ASTATION_PROVISIONING_PROFILE_BASE64",
    "ASTATION_NOTARY_PRIVATE_KEY_BASE64",
    "ASTATION_NOTARY_KEY_ID",
    "ASTATION_NOTARY_ISSUER_ID",
)


def release_version(value):
    match = re.fullmatch(r"v?((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))", value)
    if not match:
        raise ValueError("Release version must be X.Y.Z or vX.Y.Z.")
    return match[1]


def settings(env):
    version = release_version(env.get("ASTATION_RELEASE_REF", ""))
    missing = [name for name in REQUIRED if not env.get(name)]
    if missing:
        raise ValueError("Public release requires: " + ", ".join(missing))
    patterns = {
        "ASTATION_SIGNING_TEAM_ID": r"[A-Z0-9]{10}",
        "ASTATION_APPLICATION_IDENTITY": r"[a-fA-F0-9]{40}",
        "ASTATION_INSTALLER_IDENTITY": r"Developer ID Installer: .+ \(" + re.escape(env["ASTATION_SIGNING_TEAM_ID"]) + r"\)",
        "ASTATION_NOTARY_KEY_ID": r"[A-Z0-9]{10,}",
        "ASTATION_NOTARY_ISSUER_ID": r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}",
    }
    for name, pattern in patterns.items():
        if not re.fullmatch(pattern, env[name]):
            raise ValueError("Invalid release setting: " + name)
    return version


def entitlements_for_profile(profile, team, identity, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if not isinstance(profile, dict):
        raise ValueError("Provisioning profile has invalid metadata.")
    if profile.get("TeamIdentifier") != [team]:
        raise ValueError("Provisioning profile belongs to a different team.")
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        raise ValueError("A Developer ID distribution profile is required; local device profiles cannot ship.")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=datetime.timezone.utc) <= now:
        raise ValueError("Provisioning profile is expired or has no expiration.")
    allowed = profile.get("Entitlements", {})
    if not isinstance(allowed, dict):
        raise ValueError("Provisioning profile has invalid entitlements.")
    if allowed.get("com.apple.developer.team-identifier") != team:
        raise ValueError("Provisioning profile does not authorize the signing team's entitlements.")
    if allowed.get("get-task-allow") or allowed.get("com.apple.security.get-task-allow"):
        raise ValueError("A release profile must not authorize debugger access.")
    profile_id = allowed.get("com.apple.application-identifier", "")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if not isinstance(profile_id, str) or "." not in profile_id or not isinstance(prefixes, list):
        raise ValueError("Provisioning profile has no application identifier prefix.")
    prefix = profile_id.split(".", 1)[0]
    if prefix not in prefixes:
        raise ValueError("Provisioning profile has an inconsistent application identifier prefix.")
    app_id = prefix + "." + BUNDLE_ID
    if not fnmatch.fnmatchcase(app_id, profile_id):
        raise ValueError("Provisioning profile does not authorize the production bundle identifier.")
    groups = allowed.get("keychain-access-groups", [])
    if not isinstance(groups, list) or not any(
        isinstance(group, str) and fnmatch.fnmatchcase(app_id, group) for group in groups
    ):
        raise ValueError("Provisioning profile does not authorize the production Keychain group.")
    certificates = profile.get("DeveloperCertificates", [])
    if not isinstance(certificates, list) or not any(
        isinstance(cert, bytes) and hashlib.sha1(cert).hexdigest() == identity.lower()
        for cert in certificates
    ):
        raise ValueError("Provisioning profile does not authorize the signing certificate.")
    return {
        "com.apple.application-identifier": app_id,
        "com.apple.developer.team-identifier": team,
        "keychain-access-groups": [app_id],
        "com.apple.security.device.audio-input": True,
        "com.apple.security.device.camera": True,
    }


def prepare(directory, env):
    settings(env)
    directory = Path(directory)
    for name, filename in (
        ("ASTATION_SIGNING_CERTIFICATES_BASE64", "certificates.p12"),
        ("ASTATION_PROVISIONING_PROFILE_BASE64", "app.provisionprofile"),
        ("ASTATION_NOTARY_PRIVATE_KEY_BASE64", "notary.p8"),
    ):
        try:
            content = base64.b64decode("".join(env[name].split()), validate=True)
        except (ValueError, UnicodeError):
            raise ValueError("Invalid base64 in " + name) from None
        if not content:
            raise ValueError("Empty decoded signing asset: " + name)
        path = directory / filename
        with path.open("xb") as destination:
            os.chmod(path, 0o600)
            destination.write(content)
    decoded = subprocess.run(
        ["security", "cms", "-D", "-i", str(directory / "app.provisionprofile")], capture_output=True
    )
    if decoded.returncode:
        raise ValueError("Cannot decode the distribution provisioning profile.")
    try:
        profile = plistlib.loads(decoded.stdout)
    except (ValueError, plistlib.InvalidFileException):
        raise ValueError("Invalid distribution provisioning profile.") from None
    entitlements = entitlements_for_profile(
        profile, env["ASTATION_SIGNING_TEAM_ID"], env["ASTATION_APPLICATION_IDENTITY"]
    )
    with (directory / "entitlements.plist").open("xb") as destination:
        os.chmod(destination.name, 0o600)
        destination.write(plistlib.dumps(entitlements))


def verify_app(app, directory, env):
    version = settings(env)
    info = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())
    if any(info.get(key) != value for key, value in {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleVersion": version,
        "CFBundleShortVersionString": version,
    }.items()):
        raise ValueError("Packaged app has the wrong identity or version.")
    metadata = subprocess.run(["codesign", "-d", "--verbose=4", app], capture_output=True, check=True)
    lines = metadata.stderr.decode().splitlines()
    if not any(line.startswith("Authority=Developer ID Application:") for line in lines):
        raise ValueError("Packaged app is not signed with Developer ID Application.")
    if "TeamIdentifier=" + env["ASTATION_SIGNING_TEAM_ID"] not in lines:
        raise ValueError("Packaged app is signed by a different team.")
    if not any("flags=" in line and "runtime" in line for line in lines):
        raise ValueError("Packaged app is missing the hardened runtime.")
    extracted = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", app], capture_output=True, check=True
    )
    actual = plistlib.loads(extracted.stdout)
    expected = plistlib.loads((Path(directory) / "entitlements.plist").read_bytes())
    if actual != expected:
        raise ValueError("Packaged app has unexpected Keychain or runtime entitlements.")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["preflight"]:
            print(settings(os.environ))
        elif len(sys.argv) == 3 and sys.argv[1] == "prepare":
            prepare(sys.argv[2], os.environ)
        elif len(sys.argv) == 4 and sys.argv[1] == "verify-app":
            verify_app(sys.argv[2], sys.argv[3], os.environ)
        else:
            raise ValueError("Usage: release_signing.py preflight | prepare DIR | verify-app APP DIR")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Release signing failed:", error, file=sys.stderr)
        sys.exit(1)
