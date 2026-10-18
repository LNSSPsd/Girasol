#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Writes the output file map for the app's incremental Swift build.

Usage: swift_output_map.py <obj dir> <source>...  (sources absolute)

Each source gets an object and a swiftdeps record in <obj dir>, named after
its path, so the driver can tell what changed and what depends on it. The
file is only rewritten when its content changes.
"""
import json
import os
import sys


def main():
    obj_dir, sources = sys.argv[1], sys.argv[2:]
    root = os.path.commonpath(sources) if sources else ""
    entries = {"": {"swift-dependencies": os.path.join(obj_dir, "module.swiftdeps")}}
    for source in sources:
        name = os.path.relpath(source, root).replace("/", "__")[: -len(".swift")]
        base = os.path.join(obj_dir, name)
        entries[source] = {
            "object": base + ".o",
            "swift-dependencies": base + ".swiftdeps",
        }
    text = json.dumps(entries, indent=1, sort_keys=True)
    path = os.path.join(obj_dir, "files.json")
    try:
        with open(path) as existing:
            if existing.read() == text:
                return
    except OSError:
        pass
    with open(path, "w") as out:
        out.write(text)


if __name__ == "__main__":
    main()
