"""Coverage reports must not turn absent or partially covered sources into 100%."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("coverage_check", Path(__file__).with_name("check-rust-coverage.py"))
coverage_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage_check)


class CoverageReports(unittest.TestCase):
    def test_reports_inventory_and_incomplete_gate(self):
        with tempfile.TemporaryDirectory(prefix="northvault-coverage-check-") as directory:
            root = Path(directory)
            for crate in ("core", "descriptor-core"):
                (root / crate / "src").mkdir(parents=True)
                (root / crate / "src/lib.rs").write_text("pub fn fixture() {}\n")
            for path in ("core/src/sync_tests.rs", "core/src/wallet/test_keys.rs"):
                (root / path).parent.mkdir(exist_ok=True)
                (root / path).write_text("// test-only fixture\n")

            def report(crate, covered):
                return {"data": [{"files": [{
                    "filename": str(root / crate / "src/lib.rs"),
                    "summary": {"lines": {"count": 10, "covered": covered}},
                }]}]}

            (root / "core.json").write_text(json.dumps(report("core", 10)))
            (root / "descriptor.json").write_text(json.dumps(report("descriptor-core", 9)))
            (root / "core-missing.txt").write_text("")
            (root / "descriptor-missing.txt").write_text("")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(coverage_check.summarize(root, root))
                (root / "descriptor.json").write_text(json.dumps(report("descriptor-core", 10)))
                self.assertTrue(coverage_check.summarize(root, root))
                # Feature-disabled production sources must remain visible.
                (root / "core/src/device.rs").write_text("pub fn hardware() {}\n")
                self.assertFalse(coverage_check.summarize(root, root))
                # The milestone explicitly measures instrumented code, while
                # still listing missing hardware files. Full mode stays strict.
                (root / "core.json").write_text(json.dumps(report("core", 6)))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertTrue(coverage_check.summarize(root, root, 80, False))
                self.assertIn("core/src/device.rs", output.getvalue())
                self.assertFalse(coverage_check.summarize(root, root, 81, False))
                (root / "core.json").write_text(json.dumps(report("core", 5)))
                self.assertFalse(coverage_check.summarize(root, root, 80, False))
                # Every line of a critical file must execute even when the total passes.
                (root / "core/src/wallet/tx.rs").write_text("pub fn spend() {}\n")
                (root / "core.json").write_text(json.dumps(report("core", 10)))
                (root / "descriptor.json").write_text(json.dumps(report("descriptor-core", 10)))
                self.assertFalse(coverage_check.summarize(root, root, 80, False), "absent from the report")
                critical = report("core", 10)
                critical["data"][0]["files"].append({"filename": str(root / "core/src/wallet/tx.rs"), "summary": {"lines": {"count": 10, "covered": 9}}})
                (root / "core.json").write_text(json.dumps(critical))
                self.assertFalse(coverage_check.summarize(root, root, 80, False), "a never-called closure on an executed line")
                critical["data"][0]["files"][1]["summary"]["lines"]["covered"] = 10
                (root / "core.json").write_text(json.dumps(critical))
                self.assertTrue(coverage_check.summarize(root, root, 80, False))
                # The descriptor ABI is held to executed lines only.
                (root / "descriptor.json").write_text(json.dumps(report("descriptor-core", 9)))
                self.assertTrue(coverage_check.summarize(root, root, 80, False))
                (root / "core-missing.txt").write_text(f"TOTAL 99%\nUncovered Lines:\n{root}/core/src/lib.rs: 3\n{root}/core/src/wallet/tx.rs: 79, 141-142\n")
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertFalse(coverage_check.summarize(root, root, 80, False))
                self.assertIn("  core/src/wallet/tx.rs", output.getvalue())
                # A missing listing fails closed instead of passing silently.
                (root / "core-missing.txt").unlink()
                self.assertFalse(coverage_check.summarize(root, root, 80, False))
                (root / "core-missing.txt").write_text("")
                (root / "core/src/wallet/tx.rs").unlink()
                # An empty report must not count as complete.
                for name in ("core.json", "descriptor.json"):
                    (root / name).write_text('{"data":[{"files":[]}]}')
                self.assertFalse(coverage_check.summarize(root, root))
                self.assertFalse(coverage_check.summarize(root, root, 80, False))


if __name__ == "__main__":
    unittest.main()
