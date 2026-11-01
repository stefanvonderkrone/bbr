"""Regression checks for the test wiring validator."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("check_tests_wired", TOOLS / "check_tests_wired.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class TestsWiredTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "tests").mkdir()
        (self.root / ".github/workflows").mkdir(parents=True)
        (self.root / "tests/a_test.py").write_text("", encoding="utf-8")
        self.wire("", "")

    def wire(self, build, workflow):
        (self.root / "build.zig").write_text(build, encoding="utf-8")
        (self.root / ".github/workflows/ci.yml").write_text(workflow, encoding="utf-8")

    def unwired(self):
        return [message.split(":")[0] for message in checker.violations(self.root)]

    def test_a_runner_that_names_the_path_wires_it(self):
        for build, workflow in (
            ('const scripts = .{ "tests/a_test.py" };\n', ""),
            ('const url = "https://example.test"; const script = "tests/a_test.py";\n', ""),
            ("", "jobs:\n  ci:\n    steps:\n      - run: python3 tests/a_test.py\n"),
            ("", "jobs:\n  ci:\n    steps:\n      - name: Test\n        run: python3 ./tests/a_test.py\n"),
            ("", '      - run: echo "a # not a comment" && python3 tests/a_test.py\n'),
            ("", "      - run: |\n          set -e\n          python3 tests/a_test.py\n"),
        ):
            with self.subTest(build=build, workflow=workflow):
                self.wire(build, workflow)
                self.assertEqual(self.unwired(), [])

    def test_comments_labels_and_longer_paths_wire_nothing(self):
        for build, workflow in (
            ("// tests/a_test.py\n", ""),
            ("const step = b.step(); // tests/a_test.py\n", ""),
            ("", "# python3 tests/a_test.py\n"),
            ("", "      - run: python3 tests/other_test.py # tests/a_test.py\n"),
            ("", "      - name: Run tests/a_test.py\n        run: make\n"),
            ("", "        name: tests/a_test.py\n"),
            ("", "      - run: python3 tests/a_test.py.disabled\n"),
            ('const script = "tests/a_test.py.disabled";\n', ""),
            ("", "      - run: python3 old/tests/a_test.py\n"),
        ):
            with self.subTest(build=build, workflow=workflow):
                self.wire(build, workflow)
                self.assertEqual(self.unwired(), ["tests/a_test.py"])


if __name__ == "__main__":
    unittest.main()
