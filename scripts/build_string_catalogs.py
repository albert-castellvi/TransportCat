#!/usr/bin/env python3
"""Build the per-target String Catalogs from an exported XLIFF and a
translation table.

The UI source language is Catalan (``developmentLanguage: ca``). Xcode exports
every localizable key of the project with ``xcodebuild -exportLocalizations``;
this script turns that export plus ``scripts/translations.json`` into the
``.xcstrings`` files each target compiles.

Usage (from the repository root, after a successful build):

    xcodebuild -exportLocalizations -project TransportCat.xcodeproj \\
        -localizationPath /tmp/loc -exportLanguage es
    python3 scripts/build_string_catalogs.py \\
        "/tmp/loc/es.xcloc/Localized Contents/es.xliff"

``scripts/translations.json`` is a flat map from the Catalan key to its
Spanish and English values::

    {"<catalan key>": {"es": "<spanish>", "en": "<english>"}}

An App Shortcuts phrase is a string set, so its value is a list of the three
phrases instead of a single string.

The script fails when a key has no translation or when a translation's format
specifiers (``%@``, ``%lld``, ``%1$@``, ...) do not match the key's.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

SOURCE_LANGUAGE = "ca"
LANGUAGES = ("es", "en")

TRANSLATIONS_FILE = Path("scripts/translations.json")

# Every target that compiles a source file using a key needs that key in its
# own catalog. Xcode merges the Localizable table of all targets into one
# exported file, so the union is written to all three catalogs; keys a target
# does not compile are inert.
LOCALIZABLE_CATALOGS = (
    Path("TransportCat/Resources/Localizable.xcstrings"),
    Path("TransportCatWidgets/Localizable.xcstrings"),
    Path("TransportCatWatch/Localizable.xcstrings"),
)

# The App Shortcuts table is exported under the widget; the app compiles the
# same App Intents file, so it gets the catalog too.
APP_SHORTCUTS_APP_CATALOG = Path("TransportCat/Resources/AppShortcuts.xcstrings")

# Info.plist keys that are proper nouns or per-target values: never translated,
# they keep the value from Info.plist in every language.
UNTRANSLATED_KEYS = {"CFBundleName"}

TABLE_BY_FILENAME = {
    "Localizable.xcstrings": "Localizable",
    "InfoPlist.xcstrings": "InfoPlist",
    "AppShortcuts.xcstrings": "AppShortcuts",
}

# Matches a printf-style specifier: %@, %lld, %1$@, %2$lld, %.1f, %%.
SPECIFIER_RE = re.compile(r"%(?:(\d+)\$)?(?:@|lld|ld|lu|llu|d|i|u|f|g|e|s|p|%)")
POSITIONAL_RE = re.compile(r"%(\d+)\$")


def normalize_key(key: str) -> str:
    """Drop positional indices from format specifiers.

    Xcode exports ``Text("...\\(a)...\\(b)")`` as ``%1$@ ... %2$@``, but the
    runtime lookup key that SwiftUI builds for that literal is the plain
    ``%@ ... %@``. Catalog keys must be the plain form or the lookup never
    matches.
    """
    return POSITIONAL_RE.sub("%", key)


def specifiers(text: str) -> list[str]:
    """Format specifiers of a string, in order, without positional indices."""
    return [POSITIONAL_RE.sub("%", m.group(0)) for m in SPECIFIER_RE.finditer(text)]


def parse_xliff(path: Path) -> dict[tuple[str, str], list[str]]:
    """Return {(original catalog path, table): [keys]} for one XLIFF file."""
    namespace = {"x": "urn:oasis:names:tc:xliff:document:1.2"}
    tables: dict[tuple[str, str], list[str]] = defaultdict(list)
    for file_node in ET.parse(path).getroot().findall("x:file", namespace):
        original = file_node.get("original", "")
        table = TABLE_BY_FILENAME.get(original.rsplit("/", 1)[-1])
        if table is None:
            continue
        for unit in file_node.findall("x:body/x:trans-unit", namespace):
            key = unit.get("id")
            if key:
                tables[(original, table)].append(normalize_key(key))
    return dict(tables)


def load_translations(path: Path) -> dict[str, dict[str, object]]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def check_translation(key: str, entry: dict[str, object], is_string_set: bool) -> list[str]:
    errors = []
    for language in LANGUAGES:
        value = entry.get(language)
        if value is None:
            errors.append(f"{key!r}: missing {language} translation")
            continue
        if isinstance(value, list) != is_string_set:
            expected = "a list of phrases" if is_string_set else "a single string"
            errors.append(f"{key!r} ({language}): expected {expected}")
            continue
        for item in value if isinstance(value, list) else [value]:
            if not isinstance(item, str):
                errors.append(f"{key!r} ({language}): value must be a string")
            elif specifiers(item) != specifiers(key):
                errors.append(
                    f"{key!r} ({language}): format specifiers differ "
                    f"(key: {specifiers(key)}, value: {specifiers(item)})"
                )
    return errors


def build_catalogs(
    xliff_tables: dict[tuple[str, str], list[str]],
    translations: dict[str, dict[str, object]],
) -> tuple[dict[Path, dict[str, dict[str, object]]], list[str]]:
    errors: list[str] = []
    key_sets: dict[Path, list[str]] = {}

    localizable_keys: set[str] = set()
    for (original, table), keys in sorted(xliff_tables.items()):
        if table == "Localizable":
            localizable_keys.update(keys)
            continue
        key_sets[Path(original)] = [key for key in keys if key not in UNTRANSLATED_KEYS]
        if table == "AppShortcuts":
            key_sets[APP_SHORTCUTS_APP_CATALOG] = keys
    if localizable_keys:
        for path in LOCALIZABLE_CATALOGS:
            key_sets[path] = sorted(localizable_keys)

    string_set_keys = {
        key for (original, table), keys in xliff_tables.items()
        if table == "AppShortcuts" for key in keys
    }

    catalogs: dict[Path, dict[str, dict[str, object]]] = {}
    for path, keys in sorted(key_sets.items()):
        strings = catalogs.setdefault(path, {})
        for key in sorted(set(keys)):
            if key not in translations:
                errors.append(f"{key!r}: no translation in {TRANSLATIONS_FILE}")
                continue
            entry = translations[key]
            strings[key] = entry
            errors.extend(check_translation(key, entry, key in string_set_keys))

    return catalogs, errors


def catalog_entry(entry: dict[str, object]) -> dict[str, object]:
    localizations: dict[str, dict[str, object]] = {}
    for language in LANGUAGES:
        value = entry[language]
        if isinstance(value, list):
            localizations[language] = {
                "stringSet": {"state": "translated", "values": value}
            }
        else:
            localizations[language] = {
                "stringUnit": {"state": "translated", "value": value}
            }
    return {"localizations": localizations}


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("xliff", nargs="+", type=Path, help="exported .xliff files")
    parser.add_argument(
        "--translations",
        type=Path,
        default=TRANSLATIONS_FILE,
        help=f"translation table (default: {TRANSLATIONS_FILE})",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate the translations without writing the catalogs",
    )
    args = parser.parse_args()

    xliff_tables: dict[tuple[str, str], list[str]] = defaultdict(list)
    for path in args.xliff:
        for key, keys in parse_xliff(path).items():
            xliff_tables[key].extend(keys)

    catalogs, errors = build_catalogs(
        dict(xliff_tables), load_translations(args.translations)
    )
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    for path, strings in sorted(catalogs.items()):
        if not args.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                json.dumps(
                    {
                        "sourceLanguage": SOURCE_LANGUAGE,
                        "strings": {
                            key: catalog_entry(entry)
                            for key, entry in sorted(strings.items())
                        },
                        "version": "1.1",
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
        print(f"{path}: {len(strings)} keys")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
