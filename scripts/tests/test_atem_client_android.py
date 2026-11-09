import importlib.util
from pathlib import Path
import struct
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-atem-client-android.py"
spec = importlib.util.spec_from_file_location("android_consumer", SCRIPT)
android = importlib.util.module_from_spec(spec)
spec.loader.exec_module(android)


def elf(elf_class=2, machine=183, alignment=16384, file_offset=0, virtual_address=0):
    data = bytearray(256)
    data[:7] = b"\x7fELF" + bytes((elf_class, 1, 1))
    struct.pack_into("<HH", data, 16, 3, machine)
    if elf_class == 2:
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1)
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, file_offset, virtual_address, 0, 64, 64, alignment)
    else:
        struct.pack_into("<I", data, 28, 64)
        struct.pack_into("<HH", data, 42, 32, 1)
        struct.pack_into("<IIIIIIII", data, 64, 1, file_offset, virtual_address, 0, 64, 64, 5, alignment)
    return data


class AndroidArtifactTests(unittest.TestCase):
    def test_all_supported_abis_require_16k_load_alignment(self):
        for abi, elf_class, machine in [("arm64-v8a", 2, 183), ("armeabi-v7a", 1, 40), ("x86_64", 2, 62)]:
            with self.subTest(abi=abi):
                android.check_elf(elf(elf_class, machine), abi)
                with self.assertRaisesRegex(ValueError, "16 KiB"):
                    android.check_elf(elf(elf_class, machine, 4096), abi)
                with self.assertRaisesRegex(ValueError, "16 KiB"):
                    android.check_elf(elf(elf_class, machine, file_offset=1), abi)

    def test_wrong_architecture_and_truncated_elf_are_refused(self):
        with self.assertRaisesRegex(ValueError, "invalid ELF"):
            android.check_elf(elf(machine=62), "arm64-v8a")
        with self.assertRaisesRegex(ValueError, "program headers"):
            android.check_elf(elf()[:70], "arm64-v8a")


if __name__ == "__main__":
    unittest.main()
