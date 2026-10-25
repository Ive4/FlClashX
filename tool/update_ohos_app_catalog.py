"""Merge HarmonyOS app names and bundle names from HDC into the shared catalog."""

import argparse
import csv
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "assets/data/ohos_app_catalog.json"


def parse_records(text):
    records = json.loads(text.lstrip("\ufeff"))
    if not isinstance(records, list) or not records:
        raise ValueError("Expected a non-empty JSON array from 'bm dump -a -l'")
    apps = {}
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("Each app must contain bundleName and label")
        name = record.get("bundleName")
        label = record.get("label")
        if not isinstance(name, str) or not re.fullmatch(
            r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+", name
        ):
            raise ValueError(f"Invalid bundleName: {name!r}")
        if not isinstance(label, str):
            raise ValueError(f"Invalid label for {name}")
        app = {"bundleName": name, "label": label.strip() or name}
        if name in apps and apps[name] != app:
            raise ValueError(f"Conflicting labels for {name}")
        apps[name] = app
    return apps


def find_hdc(explicit=None):
    configured = explicit or os.environ.get("HDC_PATH")
    if configured:
        path = Path(configured).expanduser()
        if path.is_file():
            return path
        raise ValueError(f"HDC executable not found: {path}")
    binary = "hdc.exe" if sys.platform == "win32" else "hdc"
    on_path = shutil.which(binary)
    if on_path:
        return Path(on_path)
    roots = [
        Path(os.environ[key]).expanduser()
        for key in ("DEVECO_SDK_HOME", "HARMONYOS_SDK_HOME", "OHOS_SDK_HOME")
        if os.environ.get(key)
    ]
    if sys.platform == "darwin":
        roots.append(Path("/Applications/DevEco-Studio.app/Contents/sdk"))
    elif sys.platform == "win32" and os.environ.get("ProgramFiles"):
        roots.append(Path(os.environ["ProgramFiles"]) / "Huawei/DevEco Studio/sdk")
    for root in roots:
        for folder in ("default/openharmony/toolchains", "openharmony/toolchains", "toolchains", "."):
            candidate = root / folder / binary
            if candidate.is_file():
                return candidate
    raise ValueError("HDC not found. Use --hdc, HDC_PATH, DEVECO_SDK_HOME, or add hdc to PATH")


def run_hdc(hdc, arguments):
    result = subprocess.run(
        [str(hdc), *arguments], capture_output=True, encoding="utf-8-sig", timeout=30
    )
    if result.returncode:
        raise ValueError(f"HDC failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def query_apps(hdc, device=None):
    if not device:
        targets = run_hdc(hdc, ["list", "targets"])
        devices = [line.strip() for line in targets.splitlines() if line.strip()]
        if not devices or devices == ["[Empty]"]:
            raise ValueError("No device connected. Enable USB debugging and authorize this computer")
        if len(devices) != 1 or devices[0].startswith("["):
            raise ValueError("Connect one device or select one using --device (see 'hdc list targets')")
        device = devices[0]
    command = ["-t", device, "shell", "bm", "dump", "-a"]
    apps = parse_records(run_hdc(hdc, [*command, "-l"]))
    names = run_hdc(hdc, command)
    bundles = [
        line.strip() for line in names.splitlines()
        if re.fullmatch(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+", line.strip())
    ]
    if not bundles:
        raise ValueError("HDC did not return any bundle names")
    for name in bundles:
        apps.setdefault(name, {"bundleName": name, "label": name})
    return apps


def merge_apps(existing, incoming):
    merged = dict(existing)
    for name, app in incoming.items():
        if app["label"] == name and name in existing:
            continue
        merged[name] = app
    return [merged[name] for name in sorted(merged)]


def write_if_changed(path, content):
    data = content.encode("utf-8")
    if path.is_file() and path.read_bytes() == data:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hdc", help="Path to hdc or hdc.exe")
    parser.add_argument("--device", help="HDC target when more than one device is connected")
    parser.add_argument("--input", type=Path, help="Import a saved 'hdc shell bm dump -a -l' JSON file offline")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Catalog JSON path")
    parser.add_argument("--csv", type=Path, help="Also export a CSV for browsing in Excel")
    args = parser.parse_args(argv)
    try:
        if args.csv and args.csv.resolve() == args.output.resolve():
            raise ValueError("--csv and --output must use different paths")
        existing = parse_records(args.output.read_text(encoding="utf-8-sig")) if args.output.exists() else {}
        incoming = (
            parse_records(args.input.read_text(encoding="utf-8-sig"))
            if args.input else query_apps(find_hdc(args.hdc), args.device)
        )
        apps = merge_apps(existing, incoming)
        changed = write_if_changed(
            args.output, json.dumps(apps, ensure_ascii=False, indent=2) + "\n"
        )
        if args.csv:
            buffer = io.StringIO(newline="")
            writer = csv.DictWriter(buffer, fieldnames=("label", "bundleName"))
            writer.writeheader()
            writer.writerows(apps)
            write_if_changed(args.csv, "\ufeff" + buffer.getvalue())
        added = len(incoming.keys() - existing.keys())
        renamed = sum(
            app["bundleName"] in existing and app != existing[app["bundleName"]]
            for app in apps
        )
        print(f"{'Updated' if changed else 'Unchanged'}: {args.output}")
        print(f"Read {len(incoming)} apps; added {added}; renamed {renamed}; catalog total {len(apps)}")
        return 0
    except (ValueError, OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
