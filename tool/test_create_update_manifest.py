import hashlib
import tempfile
import unittest
from pathlib import Path
from create_update_manifest import create_manifest


class ManifestTest(unittest.TestCase):
    def test_hash_size_and_encoded_tag(self):
        workspace = Path(__file__).resolve().parents[1]
        scratch = (workspace / '.build').resolve()
        assert scratch.is_relative_to(workspace)
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as folder:
            package = Path(folder) / "FlClashX-windows-amd64.exe"
            package.write_bytes(b"installer fixture")
            result = create_manifest("Ive4/FlClashX", "v0.9.2+2026102501",
                                     "0.9.2+2026102501", {"windows-amd64": package})
            asset = result["assets"]["windows-amd64"]
            self.assertEqual(result["version"], "0.9.2")
            self.assertEqual(result["build"], 2026102501)
            self.assertEqual(asset["size"], len(b"installer fixture"))
            self.assertEqual(asset["sha256"], hashlib.sha256(b"installer fixture").hexdigest())
            self.assertIn("v0.9.2%2B2026102501", asset["url"])

    def test_rejects_upstream_repository(self):
        with self.assertRaises(ValueError):
            create_manifest("chen08209/FlClash", "v0.9.2", "0.9.2+1", {})

    def test_macos_assets_are_bound_to_their_architecture(self):
        with tempfile.TemporaryDirectory() as folder:
            image = Path(folder) / "FlClashX-0.9.5-macos-arm64.dmg"
            image.write_bytes(b"DMG fixture")
            result = create_manifest(
                "Ive4/FlClashX", "v0.9.5", "0.9.5+2026112602",
                {"macos-arm64": image},
            )
            asset = result["assets"]["macos-arm64"]
            self.assertTrue(asset["url"].endswith(f"/{image.name}"))
            self.assertEqual(asset["sha256"], hashlib.sha256(b"DMG fixture").hexdigest())
            with self.assertRaises(ValueError):
                create_manifest(
                    "Ive4/FlClashX", "v0.9.5", "0.9.5+2026112602",
                    {"macos-amd64": image},
                )

    def test_android_and_windows_share_schema_one(self):
        with tempfile.TemporaryDirectory() as folder:
            android = Path(folder) / "FlClashX-0.9.3-android-arm64-v8a.apk"
            windows = Path(folder) / "FlClashX-0.9.3-windows-arm64-setup.exe"
            android.write_bytes(b"mock APK")
            windows.write_bytes(b"mock installer")
            result = create_manifest(
                "Ive4/FlClashX", "v0.9.3-build2026111801", "0.9.3+2026111801",
                {"android-arm64-v8a": android, "windows-arm64": windows},
            )
        self.assertEqual(result["schema"], 1)
        self.assertEqual(result["assets"]["android-arm64-v8a"]["versionCode"], 2026113801)
        self.assertEqual(result["assets"]["android-arm64-v8a"]["size"], len(b"mock APK"))
        self.assertNotIn("versionCode", result["assets"]["windows-arm64"])

    def test_rejects_wrong_abi_and_unknown_asset_keys(self):
        with tempfile.TemporaryDirectory() as folder:
            package = Path(folder) / "FlClashX-0.9.3-android-x86_64.apk"
            package.write_bytes(b"mock APK")
            for target in ["android-arm64-v8a", "android-x86", "windows-arm64"]:
                with self.subTest(target=target), self.assertRaises(ValueError):
                    create_manifest("Ive4/FlClashX", "v0.9.3", "0.9.3+1", {target: package})

    def test_requires_build_and_package(self):
        for version in ["0.9.2", "0.9.2+0", "0.9.2+1"]:
            with self.assertRaises(ValueError):
                create_manifest("Ive4/FlClashX", "v0.9.2", version, {})


if __name__ == "__main__":
    unittest.main()
