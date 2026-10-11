import copy
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_signing


class ReleaseSigningTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 11, tzinfo=datetime.timezone.utc)
        self.cert = b"synthetic certificate for profile authorization tests"
        self.identity = hashlib.sha1(self.cert).hexdigest()
        self.profile = {
            "TeamIdentifier": ["PERSONAL01"],
            "ApplicationIdentifierPrefix": ["PREFIX0001"],
            "ProvisionsAllDevices": True,
            "ExpirationDate": self.now + datetime.timedelta(days=365),
            "DeveloperCertificates": [self.cert],
            "Entitlements": {
                "com.apple.application-identifier": "PREFIX0001.build.agora.astation",
                "com.apple.developer.team-identifier": "PERSONAL01",
                "keychain-access-groups": ["PREFIX0001.*"],
            },
        }

    def validate(self, profile=None, team="PERSONAL01", identity=None):
        return release_signing.entitlements_for_profile(
            self.profile if profile is None else profile, team, identity or self.identity, self.now
        )

    def test_distribution_entitlements_preserve_the_authorized_prefix(self):
        entitlements = self.validate()
        self.assertEqual(entitlements["keychain-access-groups"], ["PREFIX0001.build.agora.astation"])
        self.assertEqual(entitlements["com.apple.developer.team-identifier"], "PERSONAL01")
        self.assertNotIn("get-task-allow", entitlements)
        self.assertNotIn("com.apple.security.get-task-allow", entitlements)
        self.assertNotIn("com.apple.security.cs.disable-library-validation", entitlements)

    def test_wrong_team_or_certificate_cannot_authorize_protected_storage(self):
        with self.assertRaisesRegex(ValueError, "different team"):
            self.validate(team="OTHERTEAM0")
        with self.assertRaisesRegex(ValueError, "signing certificate"):
            self.validate(identity="a" * 40)

    def test_profile_must_authorize_the_team_entitlement(self):
        for team in [None, "OTHERTEAM0"]:
            profile = copy.deepcopy(self.profile)
            profile["Entitlements"]["com.apple.developer.team-identifier"] = team
            with self.subTest(team=team):
                with self.assertRaisesRegex(ValueError, "team's entitlements"):
                    self.validate(profile)

    def test_profile_root_must_be_a_dictionary(self):
        for profile in [[], "invalid profile", b"invalid profile"]:
            with self.subTest(profile=profile):
                with self.assertRaisesRegex(ValueError, "invalid metadata"):
                    self.validate(profile)

    def test_local_device_profiles_cannot_ship_even_with_a_valid_certificate(self):
        for all_devices in [False, None, True]:
            profile = copy.deepcopy(self.profile)
            profile["ProvisionsAllDevices"] = all_devices
            profile["ProvisionedDevices"] = ["synthetic-mac-device-id"]
            with self.subTest(all_devices=all_devices):
                with self.assertRaisesRegex(ValueError, "local device profiles"):
                    self.validate(profile)
        profile = copy.deepcopy(self.profile)
        profile.pop("ProvisionsAllDevices")
        with self.assertRaises(ValueError):
            self.validate(profile)

    def test_expired_or_missing_expiration_is_rejected(self):
        for expires in [self.now, self.now - datetime.timedelta(seconds=1), None, "tomorrow"]:
            profile = copy.deepcopy(self.profile)
            profile["ExpirationDate"] = expires
            with self.subTest(expires=expires):
                with self.assertRaisesRegex(ValueError, "expiration|expired"):
                    self.validate(profile)

    def test_debug_permissions_cannot_ship(self):
        for key in ["get-task-allow", "com.apple.security.get-task-allow"]:
            profile = copy.deepcopy(self.profile)
            profile["Entitlements"][key] = True
            with self.assertRaisesRegex(ValueError, "debugger"):
                self.validate(profile)

    def test_local_bundle_and_wrong_keychain_group_are_rejected(self):
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"]["com.apple.application-identifier"] += ".local"
        with self.assertRaisesRegex(ValueError, "production bundle"):
            self.validate(profile)
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"]["keychain-access-groups"] = ["OTHER00001.*"]
        with self.assertRaisesRegex(ValueError, "Keychain group"):
            self.validate(profile)

    def test_malformed_authorizations_fail_closed(self):
        for field, value in [
            ("ApplicationIdentifierPrefix", []), ("DeveloperCertificates", []),
            ("DeveloperCertificates", ["not a DER certificate"]), ("Entitlements", []),
        ]:
            profile = copy.deepcopy(self.profile)
            profile[field] = value
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    self.validate(profile)
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"]["keychain-access-groups"] = "PREFIX0001.*"
        with self.assertRaises(ValueError):
            self.validate(profile)

    def test_versions_are_numeric_and_cannot_inject_shell_commands(self):
        for value in ["0.4.20", "v0.4.20"]:
            self.assertEqual(release_signing.release_version(value), "0.4.20")
        for value in ["main", "v0.4.20-rc1", "v00.4.20", "v0.4.20; echo bad", "v1.2.3\n"]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    release_signing.release_version(value)

    def environment(self):
        env = {name: "synthetic-private-value" for name in release_signing.REQUIRED}
        env.update({
            "ASTATION_RELEASE_REF": "v0.4.20", "ASTATION_SIGNING_TEAM_ID": "PERSONAL01",
            "ASTATION_APPLICATION_IDENTITY": self.identity,
            "ASTATION_INSTALLER_IDENTITY": "Developer ID Installer: Example Person (PERSONAL01)",
            "ASTATION_NOTARY_KEY_ID": "TESTKEY001",
            "ASTATION_NOTARY_ISSUER_ID": "00000000-0000-0000-0000-000000000001",
        })
        return env

    def test_every_missing_credential_blocks_publication(self):
        env = self.environment()
        self.assertEqual(release_signing.settings(env), "0.4.20")
        for name in release_signing.REQUIRED:
            missing = env.copy()
            del missing[name]
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, name) as error:
                    release_signing.settings(missing)
                self.assertNotIn("synthetic-private-value", str(error.exception))

    def test_invalid_metadata_errors_do_not_print_credential_values(self):
        env = self.environment()
        for name in ["ASTATION_SIGNING_TEAM_ID", "ASTATION_APPLICATION_IDENTITY", "ASTATION_INSTALLER_IDENTITY",
                     "ASTATION_NOTARY_KEY_ID", "ASTATION_NOTARY_ISSUER_ID"]:
            invalid = env.copy()
            invalid[name] = "synthetic-private-value"
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, name) as error:
                    release_signing.settings(invalid)
                self.assertNotIn("synthetic-private-value", str(error.exception))

    def test_preflight_cli_emits_only_a_version_and_refuses_missing_inputs(self):
        script = Path(release_signing.__file__)
        env = dict(os.environ, **self.environment())
        result = subprocess.run([sys.executable, str(script), "preflight"], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "0.4.20\n")
        del env["ASTATION_NOTARY_PRIVATE_KEY_BASE64"]
        result = subprocess.run([sys.executable, str(script), "preflight"], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("ASTATION_NOTARY_PRIVATE_KEY_BASE64", result.stderr)
        self.assertNotIn("synthetic-private-value", result.stderr)

    def test_packaged_app_requires_distribution_identity_runtime_and_exact_entitlements(self):
        expected = self.validate()
        metadata = b"Authority=Developer ID Application: Example Person (PERSONAL01)\nTeamIdentifier=PERSONAL01\nCodeDirectory flags=0x10000(runtime)\n"
        cases = [
            (metadata, expected, None),
            (metadata.replace(b"Developer ID Application:", b"Apple Development:"), expected, "Developer ID Application"),
            (metadata.replace(b"TeamIdentifier=PERSONAL01", b"TeamIdentifier=OTHERTEAM0"), expected, "different team"),
            (metadata.replace(b"flags=0x10000(runtime)", b"flags=0x0(none)"), expected, "hardened runtime"),
            (metadata, dict(expected, **{"com.apple.security.get-task-allow": True}), "unexpected"),
            (metadata, dict(expected, **{"keychain-access-groups": ["OTHER00001.*"]}), "unexpected"),
        ]
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            app = directory / "Astation.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": release_signing.BUNDLE_ID,
                "CFBundleVersion": "0.4.20", "CFBundleShortVersionString": "0.4.20",
            }))
            (directory / "entitlements.plist").write_bytes(plistlib.dumps(expected))
            for reported_metadata, entitlements, failure in cases:
                responses = [
                    subprocess.CompletedProcess([], 0, stdout=b"", stderr=reported_metadata),
                    subprocess.CompletedProcess([], 0, stdout=plistlib.dumps(entitlements), stderr=b""),
                ]
                with self.subTest(failure=failure), patch.object(release_signing.subprocess, "run", side_effect=responses):
                    if failure:
                        with self.assertRaisesRegex(ValueError, failure):
                            release_signing.verify_app(str(app), str(directory), self.environment())
                    else:
                        release_signing.verify_app(str(app), str(directory), self.environment())

    def test_tag_prefix_or_stale_bundle_version_cannot_ship(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "Astation.app"
            (app / "Contents").mkdir(parents=True)
            for value in ["v0.4.20", "0.4.19"]:
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": release_signing.BUNDLE_ID,
                    "CFBundleVersion": value, "CFBundleShortVersionString": value,
                }))
                with patch.object(release_signing.subprocess, "run") as command:
                    with self.assertRaisesRegex(ValueError, "identity or version"):
                        release_signing.verify_app(str(app), temp, self.environment())
                    command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
