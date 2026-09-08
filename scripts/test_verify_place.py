"""Place verification regressions using real project and Roblox XML files."""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from xml.etree import ElementTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_place import verify_place


class PlaceVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.project_path = self.root / "default.project.json"
        self.place_path = self.root / "DriftwoodIsles.rbxlx"
        source_path = self.root / "src/server/Main.server.luau"
        source_path.parent.mkdir(parents=True)
        source = "print('verified source')\n"
        source_path.write_text(source, encoding="utf-8")
        self.script_project = {"$path": "src/server/Main.server.luau"}
        self.project = {"tree": {
            "$className": "DataModel",
            "ServerScriptService": {"Main": self.script_project},
        }}
        self.xml = ElementTree.Element("roblox", version="4")
        service = ElementTree.SubElement(self.xml, "Item", {"class": "ServerScriptService"})
        properties = ElementTree.SubElement(service, "Properties")
        ElementTree.SubElement(properties, "string", name="Name").text = "ServerScriptService"
        script = ElementTree.SubElement(service, "Item", {"class": "Script"})
        self.script_properties = ElementTree.SubElement(script, "Properties")
        ElementTree.SubElement(self.script_properties, "string", name="Name").text = "Main"
        ElementTree.SubElement(self.script_properties, "ProtectedString", name="Source").text = source

    def verify(self):
        self.project_path.write_text(json.dumps(self.project), encoding="utf-8")
        ElementTree.ElementTree(self.xml).write(self.place_path, encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            verify_place(self.project_path, self.place_path)

    def configure(self, value, xml_type, xml_text):
        self.script_project["$properties"] = {"Disabled": value}
        for property_element in self.script_properties.findall("*[@name='Disabled']"):
            self.script_properties.remove(property_element)
        ElementTree.SubElement(self.script_properties, xml_type, name="Disabled").text = xml_text

    def test_valid_minimal_place_is_verified(self):
        self.verify()

    def test_unsupported_root_directives_are_rejected(self):
        for directive, value in (
            ("$properties", {"Name": "UnverifiedDataModelName"}),
            ("$path", "src/server"),
            ("$ignoreUnknownInstances", True),
            ("$futureDirective", {}),
        ):
            with self.subTest(directive=directive):
                self.project["tree"][directive] = value
                with self.assertRaisesRegex(RuntimeError, "Unsupported project directives at root"):
                    self.verify()
                del self.project["tree"][directive]

    def test_numeric_xml_cannot_satisfy_boolean_configuration(self):
        for value, text in ((True, "1"), (False, "0")):
            for xml_type in ("float", "double", "int", "int64", "token"):
                with self.subTest(value=value, xml_type=xml_type):
                    self.configure(value, xml_type, text)
                    with self.assertRaisesRegex(RuntimeError, "Configured property mismatch"):
                        self.verify()

    def test_boolean_xml_cannot_satisfy_numeric_configuration(self):
        for value, text in ((1, "true"), (1.0, "true"), (0, "false"), (0.0, "false")):
            with self.subTest(value=value, text=text):
                self.configure(value, "bool", text)
                with self.assertRaisesRegex(RuntimeError, "Configured property mismatch"):
                    self.verify()

    def test_compatible_primitive_properties_are_verified(self):
        for value, xml_type, text in (
            (True, "bool", "true"),
            (False, "bool", "false"),
            (18, "float", "18"),
            (18.0, "int", "18"),
            (85, "double", "85"),
            (196.2, "float", "196.2"),
            (-100, "int64", "-100"),
            (1, "token", "1"),
            ("release", "string", "release"),
            ("release", "ProtectedString", "release"),
            ("", "string", None),
        ):
            with self.subTest(value=value, xml_type=xml_type):
                self.configure(value, xml_type, text)
                self.verify()

    def test_integral_properties_preserve_exact_value(self):
        self.configure(9007199254740993, "int64", "9007199254740993")
        self.verify()
        self.configure(9007199254740992, "int64", "9007199254740993")
        with self.assertRaisesRegex(RuntimeError, "Configured property mismatch"):
            self.verify()

    def test_different_primitive_values_are_rejected(self):
        for value, xml_type, text in (
            (18, "int", "19"), (18.5, "float", "18.25"),
            (True, "bool", "false"), ("true", "bool", "true"),
            ("18", "int", "18"), ("version", "string", "stale"),
        ):
            with self.subTest(value=value, xml_type=xml_type):
                self.configure(value, xml_type, text)
                with self.assertRaisesRegex(RuntimeError, "Configured property mismatch"):
                    self.verify()

    def test_unsupported_configured_values_fail_closed(self):
        for value in (None, [], {}, {"Vector3": [1, 2, 3]}, float("inf"), float("nan")):
            with self.subTest(value=value):
                self.configure(value, "double", "inf")
                with self.assertRaisesRegex(RuntimeError, "Unsupported configured property value"):
                    self.verify()


if __name__ == "__main__":
    unittest.main()
