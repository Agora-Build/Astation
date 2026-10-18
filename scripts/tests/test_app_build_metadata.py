import datetime
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class AppBuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="astation-build-metadata-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.script = self.root / "scripts/stamp-app-build.py"
        self.script.parent.mkdir()
        shutil.copyfile(ROOT / "scripts/stamp-app-build.py", self.script)
        self.plist = self.root / "Info.plist"
        self.original = plistlib.loads((ROOT / "Config/Info.plist").read_bytes())

    def stamp(self, *arguments, without_git=False):
        self.plist.write_bytes(plistlib.dumps(self.original))
        env = os.environ.copy()
        if without_git:
            env["PATH"] = str(self.root / "no-tools")
        before = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        subprocess.run(
            [sys.executable, str(self.script), str(self.plist), *arguments],
            env=env, capture_output=True, check=True,
        )
        result = plistlib.loads(self.plist.read_bytes())
        stamp = datetime.datetime.strptime(
            result["AstationBuildTimestamp"], "%Y-%m-%d %H:%M:%S UTC"
        ).replace(tzinfo=datetime.timezone.utc)
        self.assertLessEqual(before, stamp)
        self.assertLessEqual(stamp, datetime.datetime.now(datetime.timezone.utc))
        return result

    def test_release_from_source_export_preserves_bundle_identity_without_git(self):
        result = self.stamp("--version", "1.2.3", without_git=True)
        self.assertEqual(result.pop("AstationBuildVersion"), "1.2.3")
        result.pop("AstationBuildTimestamp")
        expected = dict(self.original, CFBundleVersion="1.2.3", CFBundleShortVersionString="1.2.3")
        self.assertEqual(result, expected)

    def test_development_source_export_still_packages_without_git_metadata(self):
        for without_git in (False, True):
            with self.subTest(without_git=without_git):
                result = self.stamp(without_git=without_git)
                self.assertEqual(result.pop("AstationBuildVersion"), "Development")
                result.pop("AstationBuildTimestamp")
                self.assertEqual(result, self.original)


if __name__ == "__main__":
    unittest.main()
