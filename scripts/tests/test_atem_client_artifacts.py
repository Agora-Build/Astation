import hashlib
import importlib.util
import io
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "check-atem-client-apple.py"
spec = importlib.util.spec_from_file_location("atem_client_artifacts", SCRIPT)
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


class ArtifactIntegrityTests(unittest.TestCase):
    def test_install_is_repeatable_and_refuses_a_modified_dependency(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "Package.swift").write_text("reviewed manifest")
            destination = root / "installed/AtemClient"
            artifacts.install_package(source, destination)
            artifacts.install_package(source, destination)
            (destination / "Package.swift").write_text("modified manifest")
            with self.assertRaisesRegex(ValueError, "differs"):
                artifacts.install_package(source, destination)
            self.assertEqual((destination / "Package.swift").read_text(), "modified manifest")

    def test_install_refuses_added_source_and_symlink_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "Package.swift").write_text("reviewed manifest")
            destination = root / "installed"
            artifacts.install_package(source, destination)
            (destination / "extra.swift").write_text("unexpected source")
            with self.assertRaisesRegex(ValueError, "differs"):
                artifacts.install_package(source, destination)
            alias = root / "alias"
            alias.symlink_to(destination, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                artifacts.install_package(source, alias)

    def test_modified_artifact_is_rejected(self):
        digest = hashlib.sha256(b"reviewed archive").hexdigest()
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            artifacts.check_hash(b"modified archive", digest, "artifact")

    def test_traversal_and_links_cannot_escape_private_extraction(self):
        for filename, mode in [("../outside", 0), ("/outside", 0),
                               ("nested/link", stat.S_IFLNK | 0o777)]:
            with self.subTest(filename=filename):
                data = io.BytesIO()
                with zipfile.ZipFile(data, "w") as archive:
                    entry = zipfile.ZipInfo(filename)
                    entry.external_attr = mode << 16
                    archive.writestr(entry, "outside")
                with tempfile.TemporaryDirectory() as temporary:
                    with self.assertRaisesRegex(ValueError, "unsafe"):
                        artifacts.extract_zip(data.getvalue(), Path(temporary))

    def test_normalized_duplicate_paths_cannot_replace_prior_files(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("nested/file", b"first")
            archive.writestr("nested/./file", b"replacement")
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            with self.assertRaisesRegex(ValueError, "duplicate"):
                artifacts.extract_zip(data.getvalue(), destination)
            self.assertEqual((destination / "nested/file").read_bytes(), b"first")
