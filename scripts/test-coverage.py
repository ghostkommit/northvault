"""Exercise the Swift coverage CLI against synthetic reports and real inventory."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SwiftCoverageGate(unittest.TestCase):
    def test_milestone_boundary_empty_report_and_strict_inventory(self):
        with tempfile.TemporaryDirectory(prefix="northvault-swift-coverage-") as directory:
            report = Path(directory) / "coverage.json"

            def run(covered, *arguments, envelope=10):
                files = [] if covered is None else [{
                    "filename": str(ROOT / "shared/Sources/WalletModels/Models.swift"),
                    "summary": {"lines": {"count": 5, "covered": covered}},
                }, {
                    "filename": str(ROOT / "shared/Sources/WalletCrypto/Envelope.swift"),
                    "summary": {"lines": {"count": 10, "covered": envelope}},
                }]
                report.write_text(json.dumps({"data": [{"files": files}]}))
                return subprocess.run([sys.executable, str(ROOT / "scripts/check-swift-coverage.py"),
                                       str(report), *arguments], capture_output=True, text=True)

            passed = run(4, "--min-lines", "80")
            self.assertEqual(passed.returncode, 0)
            self.assertIn("93.33%", passed.stdout)
            # The encrypted envelope must be fully covered whatever the total is.
            self.assertNotEqual(run(5, "--min-lines", "80", envelope=9).returncode, 0)
            self.assertIn("ios/NorthvaultStorageApp.swift", passed.stdout)
            self.assertNotEqual(run(1, "--min-lines", "80").returncode, 0)
            self.assertNotEqual(run(None, "--min-lines", "80").returncode, 0)
            self.assertNotEqual(run(5, "--require-full").returncode, 0)
            self.assertNotEqual(run(5, "--min-lines", "0").returncode, 0)


if __name__ == "__main__":
    unittest.main()
