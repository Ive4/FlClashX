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

    def test_requires_build_and_package(self):
        for version in ["0.9.2", "0.9.2+0", "0.9.2+1"]:
            with self.assertRaises(ValueError):
                create_manifest("Ive4/FlClashX", "v0.9.2", version, {})


if __name__ == "__main__":
    unittest.main()
