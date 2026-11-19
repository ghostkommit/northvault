# Containerized Regtest tests

From the repository root, with a running Docker engine and Docker Compose v2:

```sh
docker compose run --build --rm tests
```

This builds the images, starts Bitcoin Core, creates/loads the synthetic miner,
mines its initial 101 blocks, waits for electrs to index the chain, and runs:

- Bootstrap/readiness checks with synthetic RPC and TCP boundaries.
- Descriptor and portable Rust core integration tests.
- The live Regtest test: account creation for all seven script types, including
  singlesig and 2-of-3 multisig, receipt, real test-only signing, PSBT/QR exchange,
  broadcast/mempool acceptance, confirmation, and reopened persistence.

The command returns the test runner's exit status. Missing services and failed
readiness checks fail the command; they do not skip the live test. The ordinary
Rust suite first reports the live test as ignored, then the last command runs it
explicitly. Bitcoin and electrs remain running for subsequent test runs.

Docker is the only host dependency for this command; Make is optional
(`make docker-test` is equivalent). The first build requires Internet access and
can take several minutes, especially when compiling RocksDB. Allow several GB of
Docker disk space and at least 4 GB of VM memory. Both amd64 and arm64 are supported
by the build definition. Rust compilation is limited to two jobs by default.
On Colima, 4 CPUs and 8 GB of VM memory are recommended for the initial builds.

Source is copied into the test image, so retain `--build` after edits. Host Cargo
targets, Apple artifacts, and wallet files are excluded from the build context.
Rust dependencies are fetched and test binaries compiled during image build;
test execution uses `--locked --offline` with no Internet route.

## Service lifecycle

```sh
# Start services without running tests; return only once healthy.
docker compose up --build --wait --wait-timeout 180

# Inspect status and logs. bootstrap exiting with status 0 is expected.
docker compose ps --all
docker compose logs --tail=100 bitcoin bootstrap electrs

# Run again (one runner at a time per Compose project).
docker compose run --build --rm tests

# Stop services, preserving the disposable chain/index for later runs.
docker compose down

# Reset: delete only this Compose project's disposable node/index volumes.
docker compose down --volumes
```

Each run creates fresh temporary Northvault account databases. The synthetic
miner and chain persist in Docker volumes; bootstrap is safe to repeat and reloads
an existing miner wallet after a restart. The live test derives a fresh set of
public test-only seeds from a newly allocated miner address, so earlier runs'
transactions cannot contaminate its balances/history. These seeds are deliberately
public fixtures, never keys for real funds. For independent concurrent stacks, use
different `docker compose -p <project-name> ...` names on every command.

## Rust coverage

```sh
docker compose run --build --rm coverage
# Current milestone: 80% of measured lines (missing sources are still listed):
docker compose run --build --rm coverage sh /opt/northvault/run-coverage.sh --min-lines 80
# Optional full-source gate:
docker compose run --build --rm coverage sh /opt/northvault/run-coverage.sh --require-full
```

The separate image installs cargo-llvm-cov 0.9.1 and the pinned toolchain's LLVM
tools inside Docker. It instruments the descriptor ABI, wallet/persistence/service, and
live Regtest integration suites without running embedded unit-test modules. JSON
reports remain under `build/coverage-rust/run.*/`
even when the coverage gate fails. Each run gets a new report directory.

The summary inventories both crates' source files and lists missing files. Only
the two wholly test-only modules (`sync_tests.rs` and `wallet/test_keys.rs`) are
excluded from that inventory. The ordinary `tests` runner still executes the
supplementary unit tests. Hardware-disabled and Apple
coverage gaps are not evidence of 100% repository or integration coverage.

The first completed integration-only report is `build/coverage-rust/run.3vhsXD/`:
all 14 integration tests pass; 1,349/1,974 measured Rust source lines are covered
(68.34%), with seven source files absent. The descriptor crate measures 79/82
lines (96.34%). The explicit 100% gate exits 1, as expected. See `summary.txt`
alongside the JSON reports for file-level results and scope limitations.

## Isolation and provenance

Services run as UID 1000 with dropped Linux capabilities. Bitcoin has a writable
named data volume; other services read its RPC cookie through read-only mounts.
electrs has its own writable index volume. Bootstrap and health probes refuse an
unmarked node directory or a node reporting a network other than Regtest. The Rust
live test also verifies Electrum's Regtest genesis header before sending funds.

All services share Bitcoin's network namespace on an internal Docker network.
RPC, P2P, and Electrum listen only on that namespace's loopback interface. No ports
are published. External peer discovery/connections are disabled. No host wallet
directories, Keychain, USB devices, or Docker socket are mounted. This fixture's
software signing keys exist only in test binaries and the disposable miner.

Versions are pinned in `Dockerfile`:

- Bitcoin Core **30.4**, official Linux binaries, checked against SHA-256 hashes
  recorded in [Bitcoin Core build attestations](https://github.com/bitcoin-core/guix.sigs/blob/38e4be06c515ff9ed4949d9878d79db53a11487a/30.4/fanquake/all.SHA256SUMS).
- electrs **0.11.1**, source commit
  `35216c6d30148be8e6763d913d437330f431fc03`, built with its lockfile. electrs 0.12
  requires Core 31+ and should not be substituted without updating the stack.
- Rust **1.94.0**, matching the repository's pinned 1.94 toolchain.

Base images use version tags and Debian packages use their package repositories;
this is not a fully hermetic, digest-pinned supply chain.

## Scope and verification status

The Linux runner disables the core's optional `hardware` feature. It does not run
SwiftUI/AppKit, CryptoKit/Keychain, Apple FFI/UI suites, or physical-device checks.
Those still require the native macOS/iOS environment described in `TESTING.md`.
This setup is not evidence of 100% integration coverage.

Verified on 2026-11-02 using Colima/arm64: images build, Bitcoin and electrs become
healthy, bootstrap exits 0, and two consecutive full runs on the same chain pass
42 Rust tests (38 portable core, three descriptor, one live workflow) plus all
three bootstrap/readiness checks. The native `make test` also passes 53 tests.
amd64 runtime execution and physical hardware/Apple acceptance remain unverified.

Verification exposed and fixed two harness defects: Docker's parent-directory
re-inclusion was sending host Cargo output into the context (now explicit source
copies and a roughly 342 KB fresh test context), and fixed signer keys rediscovered
previous runs' coins (now fresh public fixture seeds per live run). No production
software signer or private-key import was added. An existing unused `WalletError`
import warning appears with hardware disabled.

Latest portable report: `build/coverage-rust/run.Kz0U3c/` passes all 21 integration
tests and covers **1,788/1,980 measured lines (90.30%)**. The 80% gate passes.
The same seven source files remain absent and hardware acceptance is unverified.
`summary.txt` lists per-file results; Swift is measured separately.

The updated standard `docker compose run --build --rm tests` also passes: 49 Rust
tests, including the live consensus workflow, plus the three service checks.
The node and indexer remain healthy, and bootstrap exits successfully.
