# Integration coverage work

The current milestone is **80% measured code coverage**, reported separately for
Rust and Swift. The longer-term target remains complete integration coverage of
supported behaviors. Passing the suites or counting test functions does not
establish full coverage; missing instrumentation stays explicit.
Production scope includes the Rust wallet and descriptor bridge, shared Apple
models/crypto/storage/UI, macOS views and state, and the iOS storage client.
Generated bindings and vendored dependencies are reported separately from
first-party code; hardware and OS service acceptance remains explicit.

## Critical-file gate and CI (2026-11-18)

Besides the 80% totals, `make coverage-rust-check` now fails unless integration
tests execute **every line** of the fund-safety files: `wallet/address.rs`,
`wallet/descriptor.rs`, `wallet/live.rs`, `wallet/tx.rs`, every `interop/` format
(descriptor, multisig setup, BSMS, labels, keystores, PSBT files, BC-UR) and the
descriptor C ABI. `make coverage-swift-check` requires the same of the encrypted
envelope (`WalletCrypto/Envelope.swift`). The lists live in
`docker/check-rust-coverage.py` and `scripts/check-swift-coverage.py`.

| Scope | Result |
| --- | --- |
| Portable Rust, integration tests only | 1,918 / 1,945 measured lines (**98.61%**); 12 of 12 critical files fully covered |
| Production Swift, four synthetic suites | 7,136 / 8,831 measured lines (**80.81%**); `Envelope.swift` 100% |

The Rust gate applies two measures to each critical file: llvm-cov's list of
unexecuted lines must be empty, and the stricter JSON summary, which also counts
a never-called closure that shares a line with executed code, must be 100%.
Unreachable error-mapping closures in these files were replaced by shared helpers
that reachable failures exercise. The one exception is the descriptor C ABI, held
to executed lines only: its panic-containment handler and the error mapper on an
infallible serialization cannot be called by any input, and they stay.

Not in the 100% set: hardware transports and device calls in `lib.rs`, the sample
backend, and Swift outside the envelope. `Repository.swift` and `Models.swift`
have every line executed (three unreachable `??` fallbacks remain); the other
Swift storage gaps are the real Keychain, device authentication, file
coordination and iCloud discovery, which the suites substitute by design.

`core/tests/regtest_interop.rs` adds six public-API workflows for the import
boundaries: extended-key format/secrecy/network checks, unsupported wallet
policies, keystore files, descriptor imports that must reproduce the same
addresses, field-by-field multisig setup and BSMS validation, and PSBT file/QR
round trips with foreign payloads. The live Regtest workflow now also checks
address usage after funding and spending and the unconfirmed-coin warning.

Two harness defects were found and fixed on the way: a Regtest chain retained
for more than a day left Core in initial block download so electrs never became
healthy (bootstrap now mines one fresh block), and the wallet UI suite read the
monospaced slashed zero of "0 of 1" by OCR (now matched by glyphs, with a
negative check).

GitHub Actions runs `make lint`, `make test`, the Docker Regtest suites with the
Rust gate, and `make build` plus the storage, panel and QR suites on every push
and pull request. Hosted runners have 1x displays, and OCR of rendered screens is
unreliable there even when snapshots are rendered into a 2x bitmap. The wallet
UI suite, the storage suite's rendered-privacy workflow (skipped with
`NORTHVAULT_SKIP_RENDERED_UI=1`, so CI reports 68 of 69 storage checks) and the
Swift coverage gate that needs them are **not** run on GitHub; run `make coverage-swift-check`
locally before changing Swift code.

## Earlier milestone result (2026-11-02)

Both measured-code gates pass:

| Scope | Covered / measured lines | Coverage | Report |
| --- | --- | --- | --- |
| Portable Rust, integration tests only | 1,788 / 1,980 | **90.30%** | `build/coverage-rust/run.Kz0U3c/` |
| Production Swift in all four synthetic suites | 7,136 / 8,831 | **80.81%** | `macos/build/coverage-swift/run.lz0592/` |

The earlier baselines were 68.34% Rust and 64.78% Swift. Rust still lists seven
absent files (five hardware implementations and two declaration modules). Swift
still lists the macOS/iOS app entry points as absent. These are measured-scope
percentages, not a whole-repository coverage claim or physical-device acceptance.
JSON and text summaries are retained; the Swift run also includes an HTML report.

Final verification: `make build`, all 69 storage workflows, panel checks, all 37
QR decode checks, and the expanded native Regtest wallet UI suite pass. The
standard Docker command passes 49 Rust tests plus three service checks, including
live funding/signing/broadcast/confirmation/reopen for all seven script types.
Bitcoin Core and electrs remain healthy; bootstrap exits 0. The ordinary native
Rust suite passes 59 tests, with the live test explicitly run separately in Docker.
The 80% gates and their empty/below-threshold/missing-inventory regression checks
pass. Full-source 100% and the manual acceptance paths below remain outstanding.

## Reusable Regtest signer

`core/tests/support/mod.rs` implements a synthetic air-gapped signer. Deterministic
private keys exist only in integration-test binaries. The application continues
to receive public keystores and PSBT signatures through its existing interfaces.
There is no software-signing production feature, private-key import, new FFI
endpoint, or emulated device in USB discovery.

This is the lower-effort alternative to running SeedSigner firmware: it implements
the existing file/BC-UR PSBT exchange and real BIP32/ECDSA/Schnorr signatures. It
does not claim to emulate SeedSigner firmware, its camera, USB transports, or
hardware confirmation screens. Tests cover all seven supported wallet script
types, including 2-of-3 multisig, on Regtest.

## Commands

| Command | What runs |
| --- | --- |
| `make test` | Core and descriptor checks, including offline Regtest integration tests; explicitly lists the live-node test as ignored |
| `cd descriptor-core && cargo test --locked` | Regtest descriptor validation through the allocated JSON C ABI |
| `make regtest-test` | Fresh Bitcoin Core + electrs, funding, PSBT signing/QR exchange, broadcast, confirmation and reopened persistence |
| `docker compose run --build --rm tests` | Containerized portable Rust suites plus live Regtest workflow; only Docker/Compose required on host |
| `make coverage-rust` / `make coverage-rust-check` | Containerized LLVM measurement of portable Rust plus live Regtest; the latter requires 80% of measured lines and still lists absent sources |
| `make storage-test` | CryptoKit + C ABI + encrypted file repository, vault model and native rendered privacy checks with synthetic secrets and substituted OS services |
| `bash scripts/test-panels.sh` | Swift state/navigation, credential cancellation, policy, device-selection and QR presentation checks |
| `bash scripts/test-qr.sh` | Branded QR rendering and independent decoding through the Rust bridge |
| `make wallet-ui-test` | Native account screens backed by freshly generated Regtest SQLite wallets and independent pixel checks |
| `make coverage-swift` | Instruments all four Swift suites and writes JSON, text and HTML reports under `macos/build/coverage-swift/run.*` |
| `make coverage-swift-check` | Requires 80% of measured Swift lines and still lists absent sources |

Run `make build` before the Swift suites if generated bindings and local libraries
have not been built. Coverage rebuilds local test libraries with instrumentation;
the next ordinary `make build` rebuilds them without instrumentation.

On macOS the storage suite also requires **Tesseract 5 with English language data**
(verified with installed Tesseract 5.5.0). Set `TESSERACT` to its executable path
if it is not on PATH. This is a local test dependency, not an app dependency;
OCR reads only synthetic temporary snapshots and makes no network requests.
Missing OCR fails the suite explicitly. To retain the native snapshots for review,
run `NORTHVAULT_UI_ARTIFACTS="$PWD/macos/build/storage-ui" make storage-test`.

Storage and wallet-backed panel checks now use `descriptors-regtest.json`, generated
from deterministic test-only keys by
`cd descriptor-core && cargo run --locked --example fixtures -- regtest`.
The original mainnet fixture remains for explicit network vectors and the existing
UI preview. The preview `AppState` now retains the injected wallet's network,
verified with a Regtest wallet rather than assuming mainnet.

The storage suite runs the original 45 checks plus eight recovery workflows in
`RecoveryChecks.swift`: malformed-envelope limits; authenticated metadata
substitution; interrupted signer-secret moves; interrupted DEK moves; add/remove/
rotate recovery slots; stale/missing-file writes; offline recovery/conflicts; and
creation/import/coordination failures. Each workflow uses real CryptoKit, the Rust
descriptor bridge and temporary files, with only Keychain and file coordination
substituted. The 53 count is checks/workflows, not a coverage percentage.

The next stage reached **65 checks/workflows**. Four additional Keychain
adapter workflows use the real Apple query/status handling with an in-memory
replacement for Security.framework's four item operations. They cover both
storage modes, access-group scoping, update/add behavior, malformed successful
responses, recovery and concurrent isolation. Public app construction still uses
Security.framework; no real Keychain record is accessed by these tests.

Eight `VaultModelChecks.swift` workflows exercise the actual UI model, repository,
CryptoKit and Regtest descriptor ABI using temporary directories, volatile
preferences, an in-memory Keychain, injected authentication and no cloud/timer.
They cover creation/discovery, lock/manual recovery/authentication, persisted
automatic-unlock suppression, key/secret management, slot changes/rotation,
encrypted import/publish/conflicts, rollback/corruption/offline recovery, and
locking across authentication, recovery and write suspension points. A reproduced
late-authentication disclosure is fixed by invalidating async access on lock.
Already-started encrypted writes may complete, but their results stay locked;
subsequent explicit recovery is tested. These are model integration tests, not
real OS authentication or rendered macOS/iOS interaction tests.

The current macOS storage suite runs **69 checks/workflows**. Three further model
workflows cover invalid signer selections and BIP-85 bounds, creation/input/cache
boundaries, and storage startup/key-save/key-deletion/discovery/offline failures.
An invalid signer selection was reproduced rotating the wallet; it now rejects
before mutation. Rejected requests are checked against both stored ciphertext
and Keychain contents, and subsequent valid recovery still runs.

The fourth workflow hosts the real `EncryptedWalletsView` in an off-screen native
AppKit window and reads its captured pixels using independent OCR. It verifies
authenticated wallet name/policy display, their absence after locking, the locked
wallet/recovery controls, and their restoration after explicit recovery. Native
hosting is necessary because SwiftUI ImageRenderer substitutes placeholder
graphics for macOS controls. Vision OCR was unavailable in this environment;
installed Tesseract performs the independent pixel checks instead. The test uses
model actions between snapshots; it does not claim mouse/keyboard, accessibility,
Touch ID or iOS interaction coverage. The AppKit-specific workflow is not compiled
for iOS, whose rendered UI acceptance remains outstanding.

### Native account screen integration

`core/examples/regtest_ui_fixture.rs` reuses the test-only signer to create a
single-signature account and a 2-of-3 reserve account through `WalletService`.
It then opens the first account with BDK's persisted-wallet API and applies
synthetic confirmed/pending observations. Reopening through the production
service verifies balances, transaction/UTXO counts, labels and derivation before
the Swift runner reads it through UniFFI. The generator refuses an existing
output directory; `make wallet-ui-test` owns a fresh temporary directory and
removes it on success or failure. It never reads an existing wallet directory.
These simulated observations are not consensus-valid funding and do not replace
the live Bitcoin Core/electrs test.

`scripts/check-wallet-ui.swift` keeps the real `ContentView` mounted while changing
account selection, privacy/unit preferences and workspace sections. Native
snapshots check portfolio totals, confirmed/pending amounts and labels, hidden
balances, satoshi formatting, UTXO selection, Send coin-control context, used and
unused addresses, Receive, wallet details, rename, unsigned transaction review,
return navigation, Settings and an unscanned account. Review uses a real BDK draft
spending a selected fixture coin and checks the exact amount/fee, missing-signature
count and air-gapped signing controls without signing or broadcasting.
`AppState` accepts isolated in-memory preview preferences and
retains the supplied service's sample/live identity. The test does not open
encrypted-wallet settings, start discovery, contact hardware, sync or broadcast.

The reusable `NativeSnapshot` helper now also keeps the storage view mounted
across lock/recovery. It reads each captured image with both page and sparse OCR
segmentation, plus an opaque high-contrast version for dark text on orange buttons.
Privacy assertions reject a leak found in any pass. All OCR passes must succeed.
The full receive address uses an exact glyph-mask comparison against independently
grouped native reference text; OCR is not reliable enough for this assertion.
A one-character `c`→`e` negative reference must fail that comparison. No character
substitutions or fuzzy matching are accepted.
The unsigned review also compares exact amount and fee glyphs and rejects a
one-satoshi payment substitution; the enabled Rename button uses an exact rendered
control match where OCR misses its orange background.
Rename additionally uses the native field editor and local window mouse events
(or native button activation) to submit a name. A real filesystem write failure
must keep the editor/error visible and preserve the original account; after the
fault is removed, reopening and submitting the editor must persist the new name,
close the panel and refresh the account. A separate wallet instance verifies the
stored result. No global events, system pointer movement or clipboard are used.
The runner requires its final completion marker as well as exit status zero,
because an AppKit CLI host can terminate before its async assertions finish.
Other workflows remain model-driven; full keyboard, toolbar, accessibility and
device acceptance are still separate gaps. Set
`NORTHVAULT_UI_ARTIFACTS="$PWD/macos/build/wallet-ui"` to retain synthetic PNGs.

### Regtest persistence failure integration

`core/tests/regtest_persistence.rs` adds seven public-API workflows using the
synthetic signer and temporary SQLite/registry/label files. Real filesystem
directories force both temporary-write and atomic-replacement failures. Tests
compare the current service, last saved bytes and a separately reopened service,
then retry after removing the fault. They cover create/rename/delete, label
updates/removal/import, first writes with no prior file, malformed BIP329 imports
after valid records, and isolation between Regtest and the other test networks
when their public descriptors produce the same account ID.

Five workflows initially reproduced uncommitted in-memory changes. Registry
operations now save candidate records before publishing account changes; label
operations parse and persist a candidate copy before replacing current labels.
A rejected import cannot leave its valid prefix queued for a later unrelated
write. These changes do not alter descriptors, signing, registry schemas or FFI.

The earlier Rust run on 2026-11-02 passed **53 tests** (40 core, ten offline Regtest
integration tests, three descriptor ABI tests), with the live-node test ignored.
Clippy passes with the same six existing `unnecessary_map_or` warnings. The new
test file passes rustfmt; repository-wide formatting still fails on pre-existing
formatting, beginning in `core/src/hwi/coldcard.rs`. The later Rust coverage measurement is recorded below. These filesystem faults do not simulate power loss or prove
fsync durability. Failed creation can leave an unregistered BDK file for retry;
successful deletion still uses the existing best-effort file cleanup.

### Live Regtest prerequisites

The container route needs only a running Docker engine and Compose v2:
`docker compose run --build --rm tests`. It builds the pinned tools, starts the
isolated Bitcoin Core/electrs services, bootstraps the miner, waits for readiness,
and runs the portable Rust suites followed by the ignored live-node test.
See [docker/README.md](docker/README.md) for versions, startup/status/reset commands,
and security boundaries. No host ports or host wallet mounts are configured.
The runner uses `--no-default-features`; hardware and Apple suites remain native.

For the alternative native `make regtest-test` command, install `bitcoind`,
`bitcoin-cli`, and `electrs` from their official sources. That runner does not
download executables or start Docker. Use `BITCOIND`, `BITCOIN_CLI`, and `ELECTRS`
to provide executable paths when they are not on PATH.

`scripts/test-regtest.py` creates fresh temporary node/wallet/index directories,
loopback listeners, RPC cookie authentication, and a synthetic miner. External
peer discovery and connections are disabled. It mines 101 blocks, waits for the
Electrum index, and runs the consensus-backed test. Teardown stops only its child
processes and removes only its temporary data, including on test failure.
The Rust test verifies Regtest RPC identity and the Electrum genesis header before
funding or broadcasting. No existing node, wallet directory, or production wallet
is used. Missing prerequisites fail the command; they do not silently skip it.

Verified on 2026-11-02 with Colima/arm64, Bitcoin Core 30.4, and electrs 0.11.1:
the images build, node/indexer health checks pass, bootstrap exits 0, and two
consecutive full runs on the same disposable chain pass **42 Rust tests**
(38 portable core, three descriptor ABI, one live consensus workflow) and all
three Python bootstrap/readiness checks. Each live workflow exercises all seven
script types. The native `make test` still passes **53 tests**, with the live test
ignored in that ordinary offline command.

The repeat run initially failed because fixed synthetic keys rediscovered previous
transactions. The live test now allocates a fresh public test seed namespace per
run, leaving the persisted chain intact. Docker source inclusion was also corrected
to exclude host Cargo artifacts and Apple toolchain configuration. No production
key handling changed. amd64 execution, Apple UI/OS acceptance, physical signers,
and the remaining coverage matrix below are not established by this run.

### Coverage evidence

Initial measurement on 2026-11-01: **1,428 / 8,699 instrumented production Swift
lines (16.42%)**, with `ios/NorthvaultStorageApp.swift` and
`macos/Northvault/NorthvaultApp.swift` absent. This is not a whole-repository
percentage. The measured run passed 45 storage checks, panel checks, and 37
rendered QR decode checks. Reports are under
`macos/build/coverage-swift/run.k3NsAv/`. The 100% gate correctly fails this baseline.

After the Regtest recovery workflows and preview-network correction, the measured
run `macos/build/coverage-swift/run.cwyEwr/` covers **1,511 / 8,699 lines (17.37%)**.
The same two entry-point files are absent. Shared envelope line coverage is
125/125, repository coverage is 116/118, models are 30/31, and key-storage code is
37/89. These are line counts, not claims of complete branch or security coverage.
The run passed all 53 storage checks/workflows, panel tests, and 37 QR image checks.
The strict gate was rerun and exited with failure as expected.

After the Keychain adapter and vault model workflows, the verified run
`macos/build/coverage-swift/run.Lg3uKe/` covers **1,918 / 8,779 instrumented Swift
lines (21.85%)**. It passes 65 storage workflows, panel tests and 37 QR image
checks. VaultModel is 342/396, Keychain is 93/107, Envelope is 125/125, and Repository
is 116/118. LLVM's Swift line totals include synthesized/overlapping function
mappings; they are not a count of distinct physical source lines. Both app entry
points are still absent. The strict gate exits 1, as required for incomplete
coverage; none of these percentages establishes full behavioral coverage.

An intermediate run (`run.bh5DI3`) is superseded: storage tests built shared
modules with `-enable-testing`, while other suites rebuilt them without it.
Combining those different mappings lost storage hits (VaultModel reported 135
covered lines in the combined report versus 342 in the storage binary alone).
The coverage runner now applies the same testability flags to all suites. In the
verified run, combined and individual VaultModel coverage both report 342/396.
Ordinary app builds still compile without the testability flag.

The preceding verified run, `macos/build/coverage-swift/run.QsFuS1/`, covers
**2,286 / 8,784 instrumented Swift lines (26.02%)** after the additional model
boundaries and native rendered privacy workflow. VaultModel covers 347/401 and
VaultView 363/576; Keychain remains 93/107 and Repository 116/118. All 69 macOS
storage workflows, panel checks and 37 QR image checks passed, and `make build`
passed. Both app entry points remain absent, and the 100% gate still exits 1.
There is still no whole-repository coverage or live-node acceptance claim.

The preceding verified report, `macos/build/coverage-swift/run.fNVHjo/`, covers
**5,677 / 8,819 instrumented Swift lines (64.37%)**. All 69 storage workflows,
panel checks, 37 QR image checks and 15 native wallet screen states passed.
The wallet suite additionally verifies exact receive/payment/fee glyphs and
rejects altered address and amount references. After correcting OCR recognition
in the wallet harness, that suite was rerun with the same instrumentation flags;
its profiles were merged with the other three passing suites using the coverage
script's report commands. No production source was excluded to raise coverage.
VaultModel remains 347/401 in the combined report, preserving the storage hits.
The separate Rust run passes 46 tests; its live-node test remains ignored.

The strict gate was run on this final report and exits **1**: 3,142 measured
Swift lines remain uncovered, and both macOS/iOS app entry points are still
absent. The largest remaining measured gaps include account setup, PIN UI,
encrypted-vault interactions, file import/export, and the camera scanner.
Rendered model transitions do not cover native clicks/typing or OS/device
acceptance. At that stage Rust source coverage and live consensus-backed Regtest
execution were unverified; the later Docker results below do not make the Swift
64.37% measurement a whole-repository percentage.

The current report, `macos/build/coverage-swift/run.hRopo5/`, covers
**5,713 / 8,819 measured Swift lines (64.78%)** after the native Rename error and
recovery workflow. All 69 storage workflows, panel checks, 37 QR checks and 18
wallet screen states passed, as did `make build` and the 53 Rust tests. The four
completed suite profiles are listed in `profile-inputs.txt`; the abandoned UI
attempt is excluded because its earlier test-harness counters differ. The final
merge has no counter mismatch and excludes no additional production sources.
The 100% gate still exits **1**: 3,106 measured Swift lines and both app entry
points remain uncovered. The later Docker results below add Rust coverage and
live-node acceptance evidence. Test counts do not establish full behavioral coverage.

The Keychain adapter and vault model now have isolated integration workflows as
described above. Most macOS views and the iOS entry point still need integration
workflows. They do not establish full native UI or physical-device coverage.

Swift reports include instrumented production code even when it has zero hits.
`scripts/check-swift-coverage.py` also inventories production Swift files absent
from the report, so unlinked app entry points or iOS code cannot silently disappear
from the scope. Pass `--require-full` with a report path to enforce the 100% gate;
it fails for any missing file or uncovered measured line. This is a line-coverage
gate, not a replacement for the behavioral and physical acceptance matrix.

### Rust integration coverage (2026-11-02)

`make coverage-rust` now runs inside Docker with cargo-llvm-cov 0.9.1 and the pinned
Rust 1.94.0 LLVM tools. No local coverage-tool installation is needed. The runner
instruments only the descriptor ABI, wallet, persistence, and live-node integration
suites; supplementary embedded unit tests run in the ordinary test command.

The first completed report is `build/coverage-rust/run.3vhsXD/` (`core.json`,
`descriptor.json`, and `summary.txt`). All **14 integration tests** pass, including
live funding/signing/broadcast/confirmation for all seven script types. The report
measures **1,349 / 1,974 Rust source lines (68.34%)**. The descriptor crate accounts
for **79 / 82 lines (96.34%)**. There are **625 uncovered measured lines** and
**seven source files absent**: five hardware implementation files plus the
declaration-only chain/wallet module files. Hardware is disabled for this Linux
profile; Swift/Apple code is measured separately. This is not a whole-repository
percentage or proof of full behavioral coverage.

`make coverage-rust-check` enforces the missing-source/100% gate. Evaluating that
gate against the completed report exits **1**, as expected. The gate's fixture
test verifies uncovered lines, absent production files, and empty reports cannot
be treated as full coverage. The two entirely test-only Rust modules are outside
the production-source inventory; no production source is silently excluded.
The largest measured gaps are `mock.rs` (0/257), `lib.rs` (311/435), hardware
stubs (0/39), and descriptor/interchange error paths. Use these reports to drive
new public-API integration workflows while retaining the separate hardware and
native Apple acceptance requirements.

## Behavior matrix and remaining work

| Area | Evidence added/existing | Still required for full coverage |
| --- | --- | --- |
| Setup/import/export | `regtest_wallet`: all 7 scripts, separate receive/change derivation, descriptor/BSMS/multisig file round trips, duplicate/invalid setup rejection | Complete malformed-file and boundary matrix; Swift import workflows |
| Account lifecycle | `regtest_wallet` plus seven `regtest_persistence` workflows: write/replacement failures, rejected-import atomicity, retry/reopen and cross-network isolation | Process interruption/power loss, cleanup failures, corruption and UI lifecycle paths |
| Signing exchange | `regtest_wallet`: actual signatures, wrong signer, duplicate scans, thresholds, reordered/repeated QR frames, changed-transaction rejection | Complete hostile PSBT matrix, cancellation/recovery across UI boundaries |
| Sync | `sync_tests` protocol fixture plus passing live Core/electrs funding, confirmation, reopen and repeated-chain workflows | Reorgs, disconnect/reconnect, mempool replacement/eviction, coinbase maturity |
| Spend/broadcast | Coin-control/fee/finalization tests plus passing live consensus validation for all seven scripts | Extend send-max, all coin-selection and fee boundaries, rejection/retry cases |
| Descriptor C ABI | `regtest_ffi`: 10 policy forms, separate/multipath branches, checksum, explicit networks, origins, wildcard/private-key rejection, sorting, invalid JSON/UTF-8/null and buffer free; 79/82 measured lines | Remaining parser/policy and defensive failure paths |
| Encrypted storage | 69 macOS Regtest checks/workflows with real CryptoKit/files, OS-adapter faults, model boundaries and rendered lock/recovery privacy | Remaining measured gaps, real Keychain/iCloud/file coordination acceptance, iOS rendering and UI interaction |
| Swift UI and app state | Panel/QR suites and 18 native screen states over persisted Regtest BDK data; exact address/payment/fee glyph checks and native Rename failure/recovery actions | Remaining native input/actions, setup and file workflows, app entry points, camera and iOS workflows |
| Hardware | Existing Trezor credential protocol and worker-lifetime tests | Additional transport emulation; physical Coldcard/Trezor/Jade confirmation, reconnect and signing checks |

The live-node suite's supported scope and OS/hardware substitutions must stay
visible in reports. Do not relax a gate, remove supported behavior, or exclude
uncovered production files simply to report 100%.

### 80% milestone: portable Rust

`build/coverage-rust/run.Kz0U3c/` covers **1,788 / 1,980 lines (90.30%)** through
21 integration tests, including the real Bitcoin Core/electrs workflow for all
seven scripts. Seven files remain absent: five hardware implementations and two
declaration-only modules. This is portable measured Rust coverage, not coverage
of hardware transports or the whole repository. Descriptor coverage is 79/82.

`regtest_service.rs` adds seven portable public-service workflows covering the
read-only preview backend, portfolio/account lifecycle, all history ranges and
quotes, unsupported writes, and hardware-disabled failure paths. They reproduced
and now protect against invalid preview fee rates, oversized amount overflow,
and receive-offset overflow. Preview quotes reuse the production fee validator;
checked arithmetic returns an error without changing accounts. The ordinary
native `make test` passes 59 tests (six service workflows; the seventh specifically
requires hardware features to be disabled).

The live workflow also checks label precedence/persistence, funded/pending/reopened
charts, maximum-send draining, and high-fee/self-recipient warnings. The
destination-independent maximum quote assumes the wallet's own output script;
a different recipient type can produce a different fee. Tests compare matching
script estimates and separately require the real recipient output plus fee to
equal the selected balance. No signing policy or production spending API changed.

Both `*-check` Make targets now use `--min-lines 80`. For the optional full-source
gate, pass `--require-full` directly to the coverage script instead. That strict
gate still fails when sources are absent; the milestone does not hide those gaps.

### Native coverage extensions for the 80% milestone

The account runner now enters synthetic public keys into the actual setup form,
reviews derived Regtest addresses, creates single-signature and 2-of-3 accounts,
and reopens the service to check the stored threshold and key count. It also
rejects a malformed public key and recovers from an actual registry-write failure
without publishing an account before the write succeeds. The multisig
form starts from an injected constrained policy; off-screen slider dragging is
not established by this test. Existing panel tests cover policy bounds and script
compatibility through Swift/UniFFI and real descriptor creation.

Other native workflows cover passphrase byte limits, exact UTF-8/whitespace
confirmation, standard-wallet versus cancellation results, masked PIN positions,
delete/submit, preference changes, and network/settings isolation. The send form
checks insufficient funds and a corrected unsigned preview without signing or
broadcasting. File export checks use an explicitly injected temporary directory;
invalid paths/names and folder collisions fail visibly, and replacement prompts
plus cancellation preserve the old bytes. Destructive replacement activation is
unverified in the off-screen host and remains a manual acceptance check.

The storage UI additionally exercises descriptor reveal/hide and the actual
encrypted backup form: wrong-network rejection, native network selection, invalid
secret rejection, encryption, dismissal, and recovery. It uses a fresh repository,
real CryptoKit/descriptor ABI, and an in-memory Keychain. Existing descriptor
deduplication is preserved; these creation checks use separate temporary stores.

`NativeSnapshot` uses local field editors, native picker/segmented-control
actions, and rendered-label or exact pixel matching. It never posts global events
or moves the system pointer. Segmented controls use target/action to avoid their
blocking mouse-tracking loop in an off-screen CLI. No real device, Keychain,
clipboard, production wallet, or cloud service is accessed. Modal window routing,
physical devices, iOS interaction, and the missing source inventory remain gaps.
