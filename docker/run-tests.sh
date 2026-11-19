#!/bin/sh
set -eu
python3 -B -m unittest discover -s /opt/northvault -p 'test_*.py'
python3 /opt/northvault/service.py electrum-health
cd /workspace/descriptor-core
cargo test --locked --offline --lib --tests
cd /workspace/core
cargo test --locked --offline --no-default-features --lib --tests
cargo test --locked --offline --no-default-features --test regtest_node -- --ignored --test-threads=1
