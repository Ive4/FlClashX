"""Generate a FlClashX release manifest from Windows installers and Android APKs."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import quote

WINDOWS_TARGETS = ("windows-amd64", "windows-arm64")
# Flutter's split APK build adds a target-specific offset to the pubspec build.
ANDROID_VERSION_OFFSETS = {
    "android-armeabi-v7a": 1000,
    "android-arm64-v8a": 2000,
    "android-x86_64": 4000,
}


def create_manifest(repository, tag, version, packages):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected owner/repo")
    if repository.lower() == "chen08209/flclash":
        raise ValueError("Use your FlClashX release repository, not upstream")
    match = re.fullmatch(r"(\d+\.\d+\.\d+)\+(\d+)", version)
    if not match or int(match[2]) <= 0:
        raise ValueError("Expected version+build, with a positive build number")
    if not tag or tag in (".", ".."):
        raise ValueError("Expected a release tag")
    build = int(match[2])
    assets = {}
    for target, package in packages.items():
        path = Path(package)
        asset = {}
        if target in ANDROID_VERSION_OFFSETS:
            expected = f"FlClashX-{match[1]}-{target}.apk"
            if path.name != expected:
                raise ValueError(f"Expected {expected}")
            version_code = build + ANDROID_VERSION_OFFSETS[target]
            if version_code > 2**31 - 1:
                raise ValueError("Android version code exceeds the signed integer range")
            asset["versionCode"] = version_code
        elif target in WINDOWS_TARGETS:
            if not path.name.startswith("FlClashX-") or path.suffix.lower() != ".exe":
                raise ValueError("Expected a FlClashX-*.exe Inno Setup installer")
        else:
            raise ValueError(f"Unsupported target: {target}")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        size = path.stat().st_size
        if not 0 < size <= 2 * 1024**3:
            raise ValueError("Invalid installer size")
        assets[target] = {
            "url": f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}/{quote(path.name, safe='')}",
            "sha256": digest.hexdigest(), "size": size,
            **asset,
        }
    if not assets:
        raise ValueError("Supply at least one Windows installer or Android APK")
    return {"schema": 1, "app": "FlClashX", "version": match[1],
            "build": build, "assets": assets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    targets = (*WINDOWS_TARGETS, *ANDROID_VERSION_OFFSETS)
    for target in targets:
        parser.add_argument(f"--{target}")
    parser.add_argument("--output", default="dist/flclashx-update.json")
    args = parser.parse_args()
    pubspec = Path(__file__).resolve().parents[1] / "pubspec.yaml"
    version = re.search(r"^version:\s*(\S+)", pubspec.read_text(), re.M)[1]
    packages = {target: value for target in targets
                if (value := getattr(args, target.replace("-", "_")))}
    manifest = create_manifest(args.repository, args.tag, version, packages)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
