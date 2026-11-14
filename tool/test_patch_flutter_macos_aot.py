import json
import tempfile
import unittest
from pathlib import Path

from patch_flutter_macos_aot import ENTRY_POINT, SDK_VERSION, STRUCTS, patch_sdk, patch_source


SOURCE = "\n\n".join(f"final class {name} extends Struct {{\n}}" for name in STRUCTS) + "\n"


class MacOSAotPatchTest(unittest.TestCase):
    def test_retains_every_struct_without_other_changes(self):
        patched = patch_source(SOURCE)
        self.assertEqual(patched.count(ENTRY_POINT), len(STRUCTS))
        self.assertEqual(patched.replace(ENTRY_POINT, ""), SOURCE)

    def test_is_idempotent_for_cached_sdks(self):
        patched = patch_source(SOURCE)
        self.assertEqual(patch_source(patched), patched)

    def test_rejects_missing_or_duplicate_declarations(self):
        for source in (SOURCE.replace("_Rect", "_RenamedRect"), SOURCE + SOURCE):
            with self.subTest(source=source), self.assertRaises(ValueError):
                patch_source(source)

    def test_sdk_guard_and_source_guard_leave_files_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version = root / "bin/cache/flutter.version.json"
            source = root / "packages/flutter/lib/src/widgets/_window_macos.dart"
            version.parent.mkdir(parents=True)
            source.parent.mkdir(parents=True)
            for sdk_version, contents in (("3.48.0", SOURCE), (SDK_VERSION, "changed source\n")):
                with self.subTest(version=sdk_version):
                    version.write_text(json.dumps({"frameworkVersion": sdk_version}), encoding="utf-8")
                    source.write_text(contents, encoding="utf-8")
                    before = source.read_bytes()
                    with self.assertRaises(ValueError):
                        patch_sdk(root)
                    self.assertEqual(source.read_bytes(), before)

    def test_patches_sdk_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version = root / "bin/cache/flutter.version.json"
            source = root / "packages/flutter/lib/src/widgets/_window_macos.dart"
            version.parent.mkdir(parents=True)
            source.parent.mkdir(parents=True)
            version.write_text(json.dumps({"frameworkVersion": SDK_VERSION}), encoding="utf-8")
            source.write_text(SOURCE, encoding="utf-8")
            self.assertTrue(patch_sdk(root))
            self.assertFalse(patch_sdk(root))
            self.assertEqual(source.read_text(encoding="utf-8"), patch_source(SOURCE))


if __name__ == "__main__":
    unittest.main()
