#!/usr/bin/env bash
# Measure the existing synthetic suites. Does not launch a real wallet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 scripts/test-coverage.py
OUT="$ROOT/macos/build/coverage-swift"
mkdir -p "$OUT"
RUN="$(mktemp -d "$OUT/run.XXXXXX")"
export NORTHVAULT_SWIFT_COVERAGE=1
# All executables must link shared modules built with the same visibility flags.
# Otherwise Swift emits different coverage mappings for testable/non-testable
# copies, and llvm-cov can discard hits when combining the binaries.
export NORTHVAULT_TESTABLE=1
export LLVM_PROFILE_FILE="$RUN/%m-%p.profraw"
bash scripts/test-storage.sh
bash scripts/test-panels.sh
bash scripts/test-qr.sh
bash scripts/test-wallet-ui.sh
xcrun llvm-profdata merge -sparse "$RUN/"*.profraw -o "$RUN/coverage.profdata"
# Exclude only generated bindings, vendored libraries and test harnesses.
# Application and shared production Swift sources remain in the denominator.
IGNORE='(/macos/Generated/|/scripts/|/shared/Tests/|/vendor/)'
OBJECTS=("$ROOT/macos/build/check-panels" -object "$ROOT/macos/build/check-qr" -object "$ROOT/shared/.local-build/storage-checks" -object "$ROOT/macos/build/check-wallet-ui")
xcrun llvm-cov export "${OBJECTS[@]}" -instr-profile="$RUN/coverage.profdata" \
  -ignore-filename-regex="$IGNORE" -summary-only > "$RUN/summary.json"
xcrun llvm-cov show "${OBJECTS[@]}" -instr-profile="$RUN/coverage.profdata" \
  -ignore-filename-regex="$IGNORE" -format=html -output-dir="$RUN/html"
xcrun llvm-cov report "${OBJECTS[@]}" -instr-profile="$RUN/coverage.profdata" \
  -ignore-filename-regex="$IGNORE" > "$RUN/report.txt"
printf 'Swift coverage artifacts: %s\n' "$RUN"
python3 scripts/check-swift-coverage.py "$RUN/summary.json" "$@"
