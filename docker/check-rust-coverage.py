#!/usr/bin/env python3
"""Report Rust source coverage without hiding sources absent from instrumentation."""
import json
import argparse
from pathlib import Path
import sys

# Fund-safety boundaries: address/descriptor/account/transaction logic, every import and
# export format, and the descriptor C ABI. Integration tests must cover every
# measured line of these files regardless of the overall percentage.
CRITICAL = [
    "core/src/wallet/address.rs",
    "core/src/wallet/descriptor.rs",
    "core/src/wallet/live.rs",
    "core/src/wallet/tx.rs",
    "core/src/interop/mod.rs",
    "core/src/interop/bsms.rs",
    "core/src/interop/coldcard.rs",
    "core/src/interop/labels.rs",
    "core/src/interop/psbt_io.rs",
    "core/src/interop/sparrow.rs",
    "core/src/interop/ur.rs",
    "descriptor-core/src/lib.rs",
]

# Held to executed lines only: its panic-containment handler and the error
# mapper on an infallible serialization are closures no input can call.
LINE_ONLY = {"descriptor-core/src/lib.rs"}


def summarize(directory, root, minimum=100, require_full=True):
    sources = set()
    for crate in ("core", "descriptor-core"):
        sources.update((root / crate / "src").rglob("*.rs"))
    # These entire files are compiled only under cfg(test), not into the wallet.
    sources -= {root / "core/src/sync_tests.rs", root / "core/src/wallet/test_keys.rs"}
    measured = {}
    for name in ("core.json", "descriptor.json"):
        report = json.loads((directory / name).read_text())
        for data in report["data"]:
            for entry in data["files"]:
                path = Path(entry["filename"])
                if path in sources:
                    # Each crate is measured by its own report, avoiding duplicate
                    # or partial dependency measurements from the other crate.
                    crate = "core" if name == "core.json" else "descriptor-core"
                    if path.is_relative_to(root / crate):
                        measured[path] = entry["summary"]["lines"]
    missing = sorted(sources - measured.keys())
    count = sum(lines["count"] for lines in measured.values())
    covered = sum(lines["covered"] for lines in measured.values())
    print(f"Measured Rust source lines: {covered}/{count} ({100 * covered / count if count else 0:.2f}%)")
    print("Measured from integration tests only; missing files prevent a repository-wide coverage claim.")
    print("Hardware is disabled in this Linux run; Apple sources and device acceptance are separate.")
    for path, lines in sorted(measured.items(), key=lambda item: item[1]["count"] - item[1]["covered"], reverse=True):
        print(f"  {path.relative_to(root)}: {lines['covered']}/{lines['count']}")
    print(f"Rust source files absent from the report: {len(missing)}")
    for path in missing:
        print(f"  {path.relative_to(root)}")
    # Two measures: llvm-cov's list of unexecuted lines, and the stricter JSON
    # summary, which also counts a never-called closure sharing an executed line.
    unexecuted = set()
    for name in ("core-missing.txt", "descriptor-missing.txt"):
        listing = directory / name
        if not listing.exists():
            unexecuted.update(root / path for path in CRITICAL)  # fail closed
            continue
        for line in listing.read_text().partition("Uncovered Lines:")[2].splitlines():
            unexecuted.add(Path(line.rpartition(": ")[0]))
    def complete(path):
        lines = measured.get(root / path)
        return lines and (root / path) not in unexecuted and (path in LINE_ONLY or lines["covered"] == lines["count"])

    incomplete = [path for path in CRITICAL if (root / path) in sources and not complete(path)]
    print(f"Critical files not fully covered: {len(incomplete)} of {len(CRITICAL)}")
    for path in incomplete:
        print(f"  {path}")
    if incomplete:
        return False
    return bool(count) and covered * 100 >= minimum * count and (not require_full or not missing)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--require-full", action="store_true")
    parser.add_argument("--min-lines", type=int, choices=range(1, 101), metavar="1..100")
    args = parser.parse_args()
    minimum = 100 if args.require_full else (args.min_lines or 80)
    complete = summarize(args.directory, Path("/workspace"), minimum, args.require_full)
    if (args.require_full or args.min_lines) and not complete:
        sys.exit(f"{minimum}% measured Rust coverage with fully covered critical files has not been achieved (full source inventory required: {args.require_full})")
