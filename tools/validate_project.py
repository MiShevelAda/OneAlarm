#!/usr/bin/env python3
"""Check the Xcode project as far as a machine without Xcode can.

This exists because the project was authored on Linux, where nothing can open it. It parses
project.pbxproj as the OpenStep plist it is, then checks referential integrity: every UUID
mentioned anywhere must be defined, every target must resolve its build phases, configuration list
and product, and the shared scheme's blueprint identifiers must point at real targets.

It cannot tell you the project builds. It can tell you the project is not malformed, which is the
failure mode you would otherwise only discover by opening Xcode.
"""

from __future__ import annotations

import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "OneAlarm.xcodeproj" / "project.pbxproj"
SCHEME = ROOT / "OneAlarm.xcodeproj" / "xcshareddata" / "xcschemes" / "OneAlarm.xcscheme"

failures: list[str] = []
notes: list[str] = []


# --- A small OpenStep plist reader -------------------------------------------------------------
# Only the subset Xcode emits: dictionaries, arrays, quoted and bare strings, and // comments.

class OpenStepParser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    def error(self, message: str) -> SyntaxError:
        line = self.text.count("\n", 0, self.pos) + 1
        return SyntaxError(f"{message} at line {line}")

    def skip(self) -> None:
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in " \t\r\n":
                self.pos += 1
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end == -1 else end
            elif self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos)
                if end == -1:
                    raise self.error("unterminated block comment")
                self.pos = end + 2
            else:
                return

    def parse(self):
        self.skip()
        value = self.parse_value()
        self.skip()
        if self.pos != len(self.text):
            raise self.error("trailing content after the root object")
        return value

    def parse_value(self):
        self.skip()
        if self.pos >= len(self.text):
            raise self.error("unexpected end of file")
        char = self.text[self.pos]
        if char == "{":
            return self.parse_dict()
        if char == "(":
            return self.parse_array()
        if char == '"':
            return self.parse_quoted()
        return self.parse_bare()

    def parse_dict(self) -> dict:
        self.pos += 1
        result: dict[str, object] = {}
        while True:
            self.skip()
            if self.pos >= len(self.text):
                raise self.error("unterminated dictionary")
            if self.text[self.pos] == "}":
                self.pos += 1
                return result
            key = self.parse_value()
            self.skip()
            if self.pos >= len(self.text) or self.text[self.pos] != "=":
                raise self.error(f"expected = after key {key!r}")
            self.pos += 1
            value = self.parse_value()
            self.skip()
            if self.pos < len(self.text) and self.text[self.pos] == ";":
                self.pos += 1
            else:
                raise self.error(f"expected ; after value for key {key!r}")
            result[key] = value

    def parse_array(self) -> list:
        self.pos += 1
        result: list[object] = []
        while True:
            self.skip()
            if self.pos >= len(self.text):
                raise self.error("unterminated array")
            if self.text[self.pos] == ")":
                self.pos += 1
                return result
            result.append(self.parse_value())
            self.skip()
            if self.pos < len(self.text) and self.text[self.pos] == ",":
                self.pos += 1

    def parse_quoted(self) -> str:
        self.pos += 1
        chars: list[str] = []
        while True:
            if self.pos >= len(self.text):
                raise self.error("unterminated string")
            char = self.text[self.pos]
            if char == "\\":
                chars.append(self.text[self.pos + 1])
                self.pos += 2
                continue
            if char == '"':
                self.pos += 1
                return "".join(chars)
            chars.append(char)
            self.pos += 1

    def parse_bare(self) -> str:
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] not in " \t\r\n=;,(){}\"":
            self.pos += 1
        if start == self.pos:
            raise self.error(f"unexpected character {self.text[self.pos]!r}")
        return self.text[start:self.pos]


def check_pbxproj() -> None:
    if not PBXPROJ.exists():
        failures.append(f"missing {PBXPROJ}")
        return

    text = PBXPROJ.read_text(encoding="utf-8")

    try:
        root = OpenStepParser(text).parse()
    except SyntaxError as exc:
        failures.append(f"project.pbxproj does not parse: {exc}")
        return

    notes.append("project.pbxproj parses as an OpenStep plist")

    objects = root.get("objects")
    if not isinstance(objects, dict):
        failures.append("project.pbxproj has no objects dictionary")
        return

    uuid_pattern = re.compile(r"^[0-9A-F]{24}$")
    for uuid in objects:
        if not uuid_pattern.match(uuid):
            failures.append(f"object key is not a 24 character hex UUID: {uuid}")

    # Every UUID-shaped token anywhere in the tree must be a defined object.
    def walk(value, path: str) -> None:
        if isinstance(value, dict):
            for key, inner in value.items():
                walk(inner, f"{path}.{key}")
        elif isinstance(value, list):
            for index, inner in enumerate(value):
                walk(inner, f"{path}[{index}]")
        elif isinstance(value, str):
            if uuid_pattern.match(value) and value not in objects:
                failures.append(f"dangling reference {value} at {path}")

    for uuid, obj in objects.items():
        isa = obj.get("isa") if isinstance(obj, dict) else None
        walk(obj, f"{isa or '?'}({uuid})")

    root_object = root.get("rootObject")
    if root_object not in objects:
        failures.append("rootObject does not resolve")
        return

    project = objects[root_object]
    if project.get("isa") != "PBXProject":
        failures.append("rootObject is not a PBXProject")
        return

    targets = project.get("targets", [])
    if not targets:
        failures.append("project defines no targets")

    target_names = []
    for target_id in targets:
        target = objects.get(target_id, {})
        name = target.get("name", "?")
        target_names.append(name)

        if target.get("isa") != "PBXNativeTarget":
            failures.append(f"target {name} is not a PBXNativeTarget")

        if target.get("productReference") not in objects:
            failures.append(f"target {name} has no resolvable product reference")

        config_list_id = target.get("buildConfigurationList")
        config_list = objects.get(config_list_id, {})
        if config_list.get("isa") != "XCConfigurationList":
            failures.append(f"target {name} has no configuration list")
        else:
            configs = [objects.get(c, {}).get("name") for c in config_list.get("buildConfigurations", [])]
            for required in ("Debug", "Release"):
                if required not in configs:
                    failures.append(f"target {name} is missing a {required} configuration")

        for phase_id in target.get("buildPhases", []):
            if phase_id not in objects:
                failures.append(f"target {name} references a missing build phase")

        # The whole point of objectVersion 77: sources come from a synchronized folder, so an empty
        # Sources phase is correct and a missing synchronized group is not.
        synced = target.get("fileSystemSynchronizedGroups", [])
        if not synced:
            failures.append(f"target {name} has no fileSystemSynchronizedGroups, so it would compile nothing")
        for group_id in synced:
            group = objects.get(group_id, {})
            if group.get("isa") != "PBXFileSystemSynchronizedRootGroup":
                failures.append(f"target {name} references a group that is not synchronized")
            else:
                folder = ROOT / group.get("path", "")
                if not folder.is_dir():
                    failures.append(f"synchronized group path does not exist on disk: {folder}")
                else:
                    swift_files = list(folder.rglob("*.swift"))
                    if not swift_files:
                        failures.append(f"synchronized folder {folder.name} contains no Swift files")
                    else:
                        notes.append(f"target {name} picks up {len(swift_files)} Swift files from {folder.name}/")

    notes.append(f"targets: {', '.join(target_names)}")

    object_version = root.get("objectVersion")
    if object_version != "77":
        failures.append(f"objectVersion is {object_version}, expected 77 for synchronized folders")

    # Settings that would produce a confusing failure rather than an obvious one.
    for uuid, obj in objects.items():
        if obj.get("isa") != "XCBuildConfiguration":
            continue
        settings = obj.get("buildSettings", {})
        if "IPHONEOS_DEPLOYMENT_TARGET" in settings:
            target_version = settings["IPHONEOS_DEPLOYMENT_TARGET"]
            if float(target_version) < 26.1:
                failures.append(
                    f"deployment target {target_version} is below 26.1, "
                    "which the AlarmKit alert initialiser needs"
                )
        for banned in ("com.apple.developer.alarmkit",):
            if banned in str(settings):
                failures.append(f"{banned} appears in build settings, and no such entitlement exists")


def check_scheme() -> None:
    if not SCHEME.exists():
        failures.append(f"missing {SCHEME}")
        return
    try:
        tree = ET.parse(SCHEME)
    except ET.ParseError as exc:
        failures.append(f"scheme is not valid XML: {exc}")
        return

    notes.append("shared scheme parses as XML")

    text = PBXPROJ.read_text(encoding="utf-8")
    for reference in tree.iter("BuildableReference"):
        blueprint = reference.get("BlueprintIdentifier", "")
        if blueprint not in text:
            failures.append(f"scheme references unknown target id {blueprint}")


def check_secrets_hygiene() -> None:
    """Nothing credential shaped may sit in the tree."""
    patterns = [
        (re.compile(r"eyJ[A-Za-z0-9_-]{20,}"), "a JWT"),
        (re.compile(r"Bearer\s+[A-Za-z0-9._-]{20,}"), "a bearer token"),
    ]
    skip_dirs = {".git", "node_modules", "DerivedData", ".build"}

    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix in {".png", ".jpg", ".pdf"}:
            continue
        if any(part in skip_dirs for part in path.parts):
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for pattern, label in patterns:
            if pattern.search(content):
                failures.append(f"{path.relative_to(ROOT)} looks like it contains {label}")

    notes.append("no token shaped strings found in the tree")


def main() -> int:
    check_pbxproj()
    check_scheme()
    check_secrets_hygiene()

    for note in notes:
        print(f"  ok   {note}")
    for failure in failures:
        print(f"  FAIL {failure}")

    if failures:
        print(f"\n{len(failures)} problem(s).")
        return 1
    print("\nProject structure is valid. This does not mean it compiles.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
