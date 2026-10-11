"""Static package checks; these cannot verify private iOS media-service behavior."""
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProjectTest(unittest.TestCase):
    def test_plists(self):
        files = list(ROOT.rglob("*.plist"))
        self.assertGreaterEqual(len(files), 4)
        for path in files:
            if "work" not in path.parts and "vendor" not in path.parts:
                with self.subTest(path=path):
                    with path.open("rb") as stream:
                        self.assertIsInstance(plistlib.load(stream), dict)

    def test_system_filter(self):
        with (ROOT / "OBSBridge.plist").open("rb") as stream:
            rule = plistlib.load(stream)
        self.assertEqual(rule["Filter"], {"Executables": ["mediaserverd"]})

    def test_rootless_architectures(self):
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn("ARCHS = arm64 arm64e", makefile)
        self.assertIn("THEOS_PACKAGE_SCHEME = rootless", makefile)
        self.assertIn("SystemHooks.mm", makefile)
        self.assertNotIn("Tweak.xm", makefile)

    def test_required_sources(self):
        for name in ["SystemHooks.mm", "Receiver.mm", "Receiver.h", "Shared.h",
                     "prefs/OBPrefs.m", "core/Timeline.cpp", "core/Timeline.hpp",
                     "tests/timeline_tests.cpp", "scripts/build_ffmpeg.sh", "README.md", "THIRD_PARTY.md"]:
            self.assertTrue((ROOT / name).is_file(), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
