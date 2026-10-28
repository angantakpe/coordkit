#!/usr/bin/env python3
"""Focused contracts for contributor and CI test selection."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("select_tests", ROOT / "scripts/select-tests.py")
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class SelectionTests(unittest.TestCase):
    def run_make(self, *arguments):
        # These calls inspect error handling, even when the test itself was
        # launched by make with an inherited TESTS command-line override.
        environment = {key: value for key, value in os.environ.items()
                       if key not in {"TESTS", "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES"}}
        return subprocess.run(["make", "test", *arguments], cwd=ROOT,
                              env=environment, capture_output=True, text=True, timeout=10)

    def test_documentation_only_needs_no_runtime_tests(self):
        self.assertEqual(selector.select_tests(["README.md", "docs/BUS.md"]), [])

    def test_runtime_source_and_wrapper_select_same_cases(self):
        source = selector.select_tests(["plugins/coordkit/scripts/core/scripts/guard.sh"])
        wrapper = selector.select_tests(["plugins/coordkit/scripts/guard.sh"])
        self.assertEqual(source, wrapper)
        self.assertIn("tests/codex-adapter.sh", source)
        self.assertNotIn("tests/linear-bridge.sh", source)

    def test_changed_test_selects_itself(self):
        self.assertEqual(selector.select_tests(["tests/presence.sh"]), ["tests/presence.sh"])

    def test_manifest_selects_package_contract(self):
        self.assertEqual(selector.select_tests(["plugins/coordkit/.claude-plugin/plugin.json"]), ["tests/plugin-package.sh"])

    def test_bridge_changes_stay_focused(self):
        self.assertEqual(selector.select_tests(["plugins/coordkit/scripts/core/scripts/linear.sh"]), ["tests/linear-bridge.sh", "tests/plugin-package.sh"])

    def test_unknown_runtime_requires_a_mapping(self):
        with self.assertRaisesRegex(ValueError, "No focused test mapping"):
            selector.select_tests(["plugins/coordkit/scripts/core/scripts/new-runtime.sh"])

    def test_selector_and_workflow_select_their_contract(self):
        for path in ["scripts/select-tests.py", "Makefile", ".github/workflows/ci.yml"]:
            self.assertIn("tests/test_selection.py", selector.select_tests([path]))

    def test_selection_is_stable_and_deduplicated(self):
        paths = ["tests/presence.sh", "tests/presence.sh", "tests/config-init.sh"]
        self.assertEqual(selector.select_tests(paths), ["tests/config-init.sh", "tests/presence.sh"])

    def test_make_requires_explicit_test_files(self):
        result = self.run_make()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TESTS=", result.stdout + result.stderr)

    def test_make_rejects_non_test_paths(self):
        result = self.run_make("TESTS=README.md")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported test", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
