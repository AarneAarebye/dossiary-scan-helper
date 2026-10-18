#!/usr/bin/env python3
"""Turns the String Catalogs in macos/Localization/ into <lang>.lproj/<Table>.strings files.

Xcode compiles .xcstrings itself; this Mac builds with the Command Line Tools only, so build-app.sh
runs this instead. Standard library only. Keys are the English text; a missing translation falls back
to English (with a warning), and --strict turns every problem() into an error.
"""
import argparse
import json
import os
import re
import sys

LANGS = ["en", "de", "es", "fr", "zh-Hans", "zh-Hant", "hy"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|@)")
SOURCE_KEY = re.compile(r'\b(?:t|L)\("([^"\\]*)"')


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def _value(entry, lang):
    return ((entry or {}).get("localizations") or {}).get(lang, {}).get("stringUnit")


def problems(catalog, langs=LANGS):
    found = []
    for key, entry in catalog["strings"].items():
        if "\n" in key or "\\" in key:
            found.append(f"{key}: key contains a newline or backslash")
        wanted = placeholders(key)
        for lang in langs:
            unit = _value(entry, lang)
            if unit is None:
                if lang != "en":
                    found.append(f"{key}: {lang} is missing")
                continue
            if unit.get("state") != "translated":
                found.append(f"{key}: {lang} is not marked translated ({unit.get('state')})")
            got = placeholders(unit.get("value", ""))
            if got != wanted:
                found.append(f"{key}: {lang} has placeholders {got} instead of {wanted}")
    return found


def _escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def strings_file(catalog, lang):
    lines = []
    for key in sorted(catalog["strings"]):
        unit = _value(catalog["strings"][key], lang)
        value = unit["value"] if unit and "value" in unit else key
        lines.append(f'"{_escape(key)}" = "{_escape(value)}";')
    return "\n".join(lines) + "\n"


def write_tables(catalog_paths, out_dir, langs=LANGS):
    written = []
    for path in catalog_paths:
        table = os.path.splitext(os.path.basename(path))[0]
        catalog = load(path)
        for lang in langs:
            folder = os.path.join(out_dir, f"{lang}.lproj")
            os.makedirs(folder, exist_ok=True)
            target = os.path.join(folder, f"{table}.strings")
            with open(target, "w", encoding="utf-8") as f:
                f.write(strings_file(catalog, lang))
            written.append(target)
    return written


def source_keys(swift_dir):
    keys = set()
    for root, _, files in os.walk(swift_dir):
        for name in files:
            if name.endswith(".swift"):
                with open(os.path.join(root, name), encoding="utf-8") as f:
                    keys.update(SOURCE_KEY.findall(f.read()))
    return keys


def source_problems(catalog, swift_dir):
    used = source_keys(swift_dir)
    known = set(catalog["strings"])
    return ([f"used but not in the catalog: {k}" for k in sorted(used - known)]
            + [f"in the catalog but not used: {k}" for k in sorted(known - used)])


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogs", nargs="+")
    parser.add_argument("--out")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--check-sources", metavar="SWIFT_DIR")
    args = parser.parse_args(argv)
    if args.check_sources:
        found = source_problems(load(args.catalogs[0]), args.check_sources)
        for p in found:
            print(p)
        return 1 if found else 0
    status = 0
    for path in args.catalogs:
        for p in problems(load(path)):
            print(f"{'error' if args.strict else 'warning'}: {os.path.basename(path)}: {p}", file=sys.stderr)
            status = 1 if args.strict else status
    if status:
        return status
    if args.out:
        for p in write_tables(args.catalogs, args.out):
            print(p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
