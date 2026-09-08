#!/usr/bin/env python3
"""Verify the shipped place contains exactly the project's current scripts.

This validates the project conventions used here, rather than emulating the
Roblox engine. Unsupported Rojo mappings fail explicitly so new asset formats
must receive an appropriate check before they become part of the release.
"""

import argparse
import json
import math
from pathlib import Path
import sys
from xml.etree import ElementTree


SCRIPT_CLASSES = {"Script", "LocalScript", "ModuleScript"}
SOURCE_DESTINATIONS = {
    "server": ("ServerScriptService",),
    "shared": ("ReplicatedStorage",),
    "client": ("StarterPlayer", "StarterPlayerScripts"),
}
ENGINE_CONTAINERS = {
    "ReplicatedStorage", "ServerScriptService", "SoundService", "StarterPlayer",
    "StarterPlayerScripts", "Workspace",
}


def script_identity(path):
    for suffix, class_name in (
        (".server.luau", "Script"), (".server.lua", "Script"),
        (".client.luau", "LocalScript"), (".client.lua", "LocalScript"),
        (".luau", "ModuleScript"), (".lua", "ModuleScript"),
    ):
        if path.name.endswith(suffix):
            return path.name[:-len(suffix)], class_name
    raise RuntimeError(f"Unsupported source mapping: {path}")


def expected_instances(project_path):
    project = json.loads(project_path.read_text(encoding="utf-8"))
    project_root = project_path.parent.resolve()
    source_root = (project_root / "src").resolve()
    expected = {}

    def add(instance_path, class_name, source=None, properties=None):
        if instance_path in expected:
            raise RuntimeError(f"Duplicate project instance: {'/'.join(instance_path)}")
        expected[instance_path] = (class_name, source, properties or {})

    def mapped(path, instance_path, class_override=None, properties=None):
        path = path.resolve()
        if not path.is_relative_to(source_root):
            raise RuntimeError(f"Production source must be under src, not {path}")
        if path.is_file():
            _, class_name = script_identity(path)
            source_parts = path.relative_to(source_root).parts
            if ".spec." in path.name or "tests" in source_parts:
                raise RuntimeError(f"Test source must not ship: {path}")
            destination = SOURCE_DESTINATIONS.get(source_parts[0])
            if destination is None or instance_path[:len(destination)] != destination:
                raise RuntimeError(f"Incorrect service placement for source: {path}")
            if class_name == "Script" and source_parts[0] != "server":
                raise RuntimeError(f"Server scripts must be under src/server: {path}")
            if class_name == "LocalScript" and source_parts[0] != "client":
                raise RuntimeError(f"Client scripts must be under src/client: {path}")
            if class_override and class_override != class_name:
                raise RuntimeError(f"Script class override disagrees with filename: {path}")
            add(instance_path, class_name, path, properties)
            return
        if not path.is_dir():
            raise RuntimeError(f"Missing mapped source: {path}")
        children = sorted(child for child in path.iterdir() if not child.name.startswith("."))
        initializers = [child for child in children if child.is_file() and child.name.startswith("init.")]
        if len(initializers) > 1:
            raise RuntimeError(f"Multiple source initializers: {path}")
        if initializers:
            mapped(initializers[0], instance_path, class_override, properties)
        else:
            add(instance_path, class_override or "Folder", properties=properties)
        for child in children:
            if child in initializers:
                continue
            name = child.name if child.is_dir() else script_identity(child)[0]
            mapped(child, instance_path + (name,))

    def visit(name, node, parent):
        instance_path = parent + (name,)
        unsupported = set(key for key in node if key.startswith("$")) - {"$className", "$path", "$properties"}
        if unsupported:
            raise RuntimeError(f"Unsupported project directives at {'/'.join(instance_path)}: {sorted(unsupported)}")
        properties = node.get("$properties", {})
        if "$path" in node:
            mapped(project_root / node["$path"], instance_path, node.get("$className"), properties)
        else:
            class_name = node.get("$className", name if name in ENGINE_CONTAINERS else "Folder")
            add(instance_path, class_name, properties=properties)
        for child_name, child_node in node.items():
            if not child_name.startswith("$"):
                visit(child_name, child_node, instance_path)

    tree = project["tree"]
    if tree.get("$className") != "DataModel":
        raise RuntimeError("The project root must be a DataModel")
    unsupported = {key for key in tree if key.startswith("$")} - {"$className"}
    if unsupported:
        raise RuntimeError(f"Unsupported project directives at root: {sorted(unsupported)}")
    for name, node in tree.items():
        if not name.startswith("$"):
            visit(name, node, ())
    return expected


def property_value(element):
    if element.tag == "bool":
        if element.text not in ("true", "false"):
            raise RuntimeError("Invalid boolean property in place")
        return element.text == "true"
    if element.tag in {"int", "int64", "token"}:
        return int(element.text)
    if element.tag in {"float", "double"}:
        return float(element.text)
    if element.tag in {"string", "ProtectedString"}:
        return element.text or ""
    raise RuntimeError(f"Unsupported configured property type: {element.tag}")


def compatible_property_type(element, configured_value):
    # bool subclasses int in Python, but these are distinct Roblox property
    # types. Check exact JSON primitive types before comparing their values.
    if type(configured_value) is bool:
        return element is not None and element.tag == "bool"
    if type(configured_value) is str:
        return element is not None and element.tag in {"string", "ProtectedString"}
    if type(configured_value) is int or (
        type(configured_value) is float and math.isfinite(configured_value)
    ):
        return element is not None and element.tag in {"float", "double", "int", "int64", "token"}
    raise RuntimeError(f"Unsupported configured property value: {configured_value!r}")


def verify_place(project_path, place_path):
    expected = expected_instances(project_path)
    root = ElementTree.parse(place_path).getroot()
    if root.tag != "roblox" or root.get("version") != "4":
        raise RuntimeError("Expected a Roblox XML version 4 place")
    actual = {}

    def visit(item, parent):
        properties = item.find("Properties")
        name = properties.find("*[@name='Name']") if properties is not None else None
        if name is None or not name.text:
            raise RuntimeError("Every shipped instance must have a name")
        instance_path = parent + (name.text,)
        if instance_path in actual:
            raise RuntimeError(f"Duplicate shipped instance: {'/'.join(instance_path)}")
        actual[instance_path] = item
        for child in item.findall("Item"):
            visit(child, instance_path)

    for item in root.findall("Item"):
        visit(item, ())
    missing, extra = expected.keys() - actual.keys(), actual.keys() - expected.keys()
    if missing or extra:
        detail = [f"missing {'/'.join(path)}" for path in sorted(missing)]
        detail += [f"unexpected {'/'.join(path)}" for path in sorted(extra)]
        raise RuntimeError("Place hierarchy mismatch: " + "; ".join(detail))
    script_count = 0
    for instance_path, (class_name, source, properties) in expected.items():
        item = actual[instance_path]
        label = "/".join(instance_path)
        if item.get("class") != class_name:
            raise RuntimeError(f"Wrong class at {label}: expected {class_name}, got {item.get('class')}")
        if class_name in SCRIPT_CLASSES:
            if source is None:
                raise RuntimeError(f"Script has no verified source: {label}")
            embedded = item.find("Properties/*[@name='Source']")
            if embedded is None or (embedded.text or "") != source.read_text(encoding="utf-8"):
                raise RuntimeError(f"Embedded source differs from current source: {label}")
            script_count += 1
        for property_name, value in properties.items():
            element = item.find(f"Properties/*[@name='{property_name}']")
            if not compatible_property_type(element, value) or property_value(element) != value:
                raise RuntimeError(f"Configured property mismatch: {label}.{property_name}")
    if not script_count:
        raise RuntimeError("Refusing to verify a place with no scripts")
    print(f"Place verification: {len(actual)} instances, {script_count} exact source embeddings, configured properties passed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("place", type=Path)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1] / "default.project.json")
    args = parser.parse_args()
    try:
        verify_place(args.project.resolve(), args.place.resolve())
    except (OSError, ValueError, RuntimeError, ElementTree.ParseError) as error:
        print(f"Place verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
