"""Retain Flutter 3.47.6 macOS FFI structs for release AOT compilation."""
import argparse
import json
import re
from pathlib import Path


SDK_VERSION = "3.47.6"
STRUCTS = ("_WindowCreationRequest", "_Size", "_Offset", "_Rect", "_Constraints")
ENTRY_POINT = "@pragma('vm:entry-point')\n"


def patch_source(source):
    declarations = []
    for name in STRUCTS:
        pattern = rf"(?m)^final class {re.escape(name)} extends Struct \{{$"
        matches = list(re.finditer(pattern, source))
        if len(matches) != 1:
            raise ValueError(f"Expected one {name} declaration; review flutter/flutter#191575")
        declarations.append(matches[0].start())
    patched = source
    for position in reversed(sorted(declarations)):
        if not source[:position].endswith(ENTRY_POINT):
            patched = patched[:position] + ENTRY_POINT + patched[position:]
    return patched


def patch_sdk(root):
    version_file = root / "bin/cache/flutter.version.json"
    version = json.loads(version_file.read_text(encoding="utf-8"))["frameworkVersion"]
    if version != SDK_VERSION:
        raise ValueError(f"Expected Flutter {SDK_VERSION}, got {version}; review the AOT workaround")
    source_file = root / "packages/flutter/lib/src/widgets/_window_macos.dart"
    source = source_file.read_text(encoding="utf-8")
    patched = patch_source(source)
    if patched == source:
        return False
    source_file.write_text(patched, encoding="utf-8", newline="\n")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("flutter_root", type=Path)
    args = parser.parse_args()
    try:
        changed = patch_sdk(args.flutter_root)
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    print("Retained macOS FFI structs" if changed else "macOS FFI structs already retained")


if __name__ == "__main__":
    main()
