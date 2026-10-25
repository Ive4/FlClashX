import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import update_ohos_app_catalog as catalog


class AppCatalogTest(unittest.TestCase):
    def setUp(self):
        workspace = Path(__file__).resolve().parents[1]
        scratch = (workspace / ".dart_tool").resolve()
        self.assertTrue(scratch.is_relative_to(workspace))
        scratch.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)

    def records(self, *records):
        return catalog.parse_records(json.dumps(records, ensure_ascii=False))

    def test_parse_preserves_unicode_and_discards_device_metadata(self):
        result = catalog.parse_records('\ufeff[{"bundleName":"com.example.a","label":" 应用A ","uid":123,"deviceId":"private"}]')
        self.assertEqual(result, {"com.example.a": {"bundleName": "com.example.a", "label": "应用A"}})

    def test_rejects_invalid_or_empty_dumps(self):
        for text in ("[Empty]", "[]", "{}", '[null]', '[{"bundleName":"bad","label":"A"}]',
                     '[{"bundleName":"com.example.a","label":null}]'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                catalog.parse_records(text)

    def test_conflicting_duplicates_require_review(self):
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            self.records({"bundleName": "com.example.a", "label": "A"},
                         {"bundleName": "com.example.a", "label": "B"})

    def test_merge_keeps_other_devices_apps_and_existing_friendly_labels(self):
        existing = self.records({"bundleName": "com.example.a", "label": "A"},
                                {"bundleName": "com.example.b", "label": "B"})
        incoming = self.records({"bundleName": "com.example.a", "label": ""},
                                {"bundleName": "com.example.b", "label": "新版B"},
                                {"bundleName": "com.example.c", "label": "C"})
        self.assertEqual(catalog.merge_apps(existing, incoming), [
            {"bundleName": "com.example.a", "label": "A"},
            {"bundleName": "com.example.b", "label": "新版B"},
            {"bundleName": "com.example.c", "label": "C"},
        ])

    def test_query_selects_single_device_and_includes_apps_without_labels(self):
        with patch.object(catalog, "run_hdc", side_effect=[
            "target-id\n", '[{"bundleName":"com.example.a","label":"A"}]',
            "ID: 100:\n\tcom.example.a\n\tcom.example.no_label\n",
        ]) as run:
            result = catalog.query_apps(Path("SDK with spaces/hdc"))
        self.assertIn("com.example.a", result)
        self.assertEqual(result["com.example.no_label"]["label"], "com.example.no_label")
        self.assertEqual(run.call_args_list[1].args[1], ["-t", "target-id", "shell", "bm", "dump", "-a", "-l"])
        self.assertEqual(run.call_args_list[2].args[1], ["-t", "target-id", "shell", "bm", "dump", "-a"])

    def test_query_requires_explicit_selection_for_multiple_devices(self):
        for targets in ("", "[Empty]\n", "device-one\ndevice-two\n"):
            with self.subTest(targets=targets), patch.object(catalog, "run_hdc", return_value=targets), self.assertRaises(ValueError):
                catalog.query_apps(Path("hdc"))

    def test_sdk_environment_discovery_on_windows_and_macos(self):
        for platform, binary in (("win32", "hdc.exe"), ("darwin", "hdc")):
            with self.subTest(platform=platform):
                sdk = self.folder / platform / "DevEco Studio SDK"
                executable = sdk / "default/openharmony/toolchains" / binary
                executable.parent.mkdir(parents=True)
                executable.touch()
                with patch.object(catalog.sys, "platform", platform), patch.dict(os.environ, {"DEVECO_SDK_HOME": str(sdk)}, clear=True), patch.object(catalog.shutil, "which", return_value=None):
                    self.assertEqual(catalog.find_hdc(), executable)

    def test_offline_update_is_repeatable_and_exports_csv(self):
        source = self.folder / "source.json"
        source.write_text('[{"bundleName":"com.example.a","label":"应用A","uid":42}]', encoding="utf-8")
        destination = self.folder / "catalog.json"
        csv = self.folder / "apps.csv"
        args = ["--input", str(source), "--output", str(destination), "--csv", str(csv)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(catalog.main(args), 0)
            modified = destination.stat().st_mtime_ns
            self.assertEqual(catalog.main(args), 0)
        self.assertEqual(destination.stat().st_mtime_ns, modified)
        self.assertNotIn("uid", destination.read_text(encoding="utf-8"))
        self.assertIn("应用A", csv.read_text(encoding="utf-8-sig"))

    def test_bad_input_does_not_replace_existing_catalog(self):
        destination = self.folder / "catalog.json"
        original = b'[{"bundleName":"com.example.a","label":"A"}]'
        destination.write_bytes(original)
        source = self.folder / "bad.json"
        source.write_text("[]", encoding="utf-8")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(catalog.main(["--input", str(source), "--output", str(destination)]), 1)
        self.assertEqual(destination.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
