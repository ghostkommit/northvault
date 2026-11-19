#!/usr/bin/env python3
"""Report measured coverage and source files absent from instrumentation.

This never treats unlinked/uninstrumented production sources as covered.
Use --min-lines 80 for the measured-code milestone, or --require-full for
the stricter 100% source-inventory gate.
"""
import json
import argparse
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("report", type=Path)
parser.add_argument("--lcov", type=Path, help="lcov export used for the executed-line gate")
parser.add_argument("--require-full", action="store_true")
parser.add_argument("--min-lines", type=int, choices=range(1, 101), metavar="1..100")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
report = json.loads(args.report.read_text())
files = {}
for data in report["data"]:
    for entry in data["files"]:
        files[Path(entry["filename"]).resolve()] = entry["summary"]["lines"]
sources = set()
for directory in ["macos/Northvault", "shared/Sources", "ios", "apple"]:
    sources.update(p.resolve() for p in (root / directory).rglob("*.swift"))
included = {path: lines for path, lines in files.items() if path in sources}
missing = sorted(sources - included.keys())
count = sum(lines["count"] for lines in included.values())
covered = sum(lines["covered"] for lines in included.values())
print(f"Instrumented production Swift lines: {covered}/{count} ({100 * covered / count if count else 0:.2f}%)")
print(f"Production source files absent from this report: {len(missing)}")
for path in missing:
    print(f"  {path.relative_to(root)}")
if missing:
    print("This is not a repository-wide coverage percentage; absent files remain uncovered.")
# The encrypted envelope (AES-GCM, HKDF, slot manifest) must stay fully covered.
CRITICAL = [root / "shared/Sources/WalletCrypto/Envelope.swift"]
partial = [p for p in CRITICAL if p not in included or included[p]["covered"] != included[p]["count"]]
# The validation bridge and the encrypted repository must have every line executed.
# (Their only unexecuted regions are `??` fallbacks for states the Rust ABI never returns.)
EVERY_LINE = [root / "shared/Sources/WalletModels/Models.swift", root / "shared/Sources/WalletStorage/Repository.swift"]
unexecuted, current = set(EVERY_LINE), None  # fail closed without an lcov export
if args.lcov and args.lcov.exists():
    unexecuted = set()
    seen = set()
    for line in args.lcov.read_text().splitlines():
        if line.startswith("SF:"):
            current = Path(line[3:]).resolve()
            seen.add(current)
        elif line.startswith("DA:") and line.endswith(",0"):
            unexecuted.add(current)
    unexecuted |= set(EVERY_LINE) - seen
partial += [p for p in EVERY_LINE if p in unexecuted]
for path in partial:
    print(f"Critical file below 100% line coverage: {path.relative_to(root)}")
if (args.require_full or args.min_lines) and partial:
    sys.exit("Critical Swift sources are not fully covered")
if args.require_full and (missing or count == 0 or covered != count):
    sys.exit("100% Swift coverage has not been achieved")
if args.min_lines and (count == 0 or covered * 100 < args.min_lines * count):
    sys.exit(f"{args.min_lines}% measured Swift coverage has not been achieved")
