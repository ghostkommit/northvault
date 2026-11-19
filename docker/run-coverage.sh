#!/bin/sh
set -eu
python3 /opt/northvault/service.py electrum-health
report_dir=$(mktemp -d /reports/run.XXXXXX)
printf 'Coverage artifacts: %s\n' "$report_dir"

cd /workspace/descriptor-core
cargo llvm-cov --locked --offline --test regtest_ffi --no-report
cargo llvm-cov report --json --output-path "$report_dir/descriptor.json"
cargo llvm-cov report --show-missing-lines > "$report_dir/descriptor-missing.txt"

cd /workspace/core
cargo llvm-cov --locked --offline --no-default-features --test regtest_wallet --test regtest_persistence --test regtest_service --test regtest_interop --no-report
cargo llvm-cov --locked --offline --no-default-features --test regtest_node --no-report -- --ignored --test-threads=1
cargo llvm-cov report --json --output-path "$report_dir/core.json"
cargo llvm-cov report --show-missing-lines > "$report_dir/core-missing.txt"

# Preserve reports even when a requested coverage gate fails.
python3 /opt/northvault/check-rust-coverage.py "$report_dir" "$@"
