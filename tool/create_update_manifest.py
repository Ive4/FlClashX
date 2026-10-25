"""Generate a FlClashX release manifest from real Windows installer bytes."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import quote


def create_manifest(repository, tag, version, packages):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected owner/repo")
    if repository.lower() == "chen08209/flclash":
        raise ValueError("Use your FlClashX release repository, not upstream")
    match = re.fullmatch(r"(\d+\.\d+\.\d+)\+(\d+)", version)
    if not match or int(match[2]) <= 0:
        raise ValueError("Expected version+build, with a positive build number")
    assets = {}
    for target, package in packages.items():
        path = Path(package)
        if not path.name.startswith("FlClashX-") or path.suffix.lower() != ".exe":
            raise ValueError("Expected a FlClashX-*.exe Inno Setup installer")
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
        }
    if not assets:
        raise ValueError("Supply at least one Windows installer")
    return {"schema": 1, "app": "FlClashX", "version": match[1],
            "build": int(match[2]), "assets": assets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--windows-amd64")
    parser.add_argument("--windows-arm64")
    parser.add_argument("--output", default="dist/flclashx-update.json")
    args = parser.parse_args()
    pubspec = Path(__file__).resolve().parents[1] / "pubspec.yaml"
    version = re.search(r"^version:\s*(\S+)", pubspec.read_text(), re.M)[1]
    packages = {target: value for target, value in {
        "windows-amd64": args.windows_amd64,
        "windows-arm64": args.windows_arm64}.items() if value}
    manifest = create_manifest(args.repository, args.tag, version, packages)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
