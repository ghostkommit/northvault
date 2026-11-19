# Security review checklist

Integration coverage work and current execution limitations are tracked in
[TESTING.md](TESTING.md). The Regtest software signer lives exclusively under
`core/tests/`; the test-only `regtest_ui_fixture` example reuses it to generate
temporary Regtest UI data. It must never be exposed through production features
or FFI. The fixture uses simulated BDK observations, not consensus-valid funding.
The live runner creates isolated loopback-only Bitcoin Core/electrs processes,
checks Regtest identity, and uses only synthetic funds. Its consensus-backed test
is not counted as passing until the required binaries are available and it runs.

This code was written with AI assistance. It needs normal human code
review before it is merged anywhere. The parts below handle funds, keys or addresses
and are **security-sensitive**. Each file starts with a `SECURITY-SENSITIVE` header.

Northvault is **watch-only**: the app never holds private keys. Everything a reviewer
signs off should keep that true.

## Files to review

| Area | File | What to check |
|---|---|---|
| Descriptors | `core/src/wallet/descriptor.rs` | Sparrow default paths, `sortedmulti` only, SLIP-132 → xpub mapping, xprv/tprv rejected, network check, path-depth check, imported descriptors rebuilt and compared address by address |
| Recipient addresses | `core/src/wallet/address.rs` | Checksum and network enforced; BIP21 parsing ignores everything but the address |
| Spending | `core/src/wallet/tx.rs` | Coin control uses only the selected outputs; fee rate limits (refuse > 1000 sat/vB, warn > 500 or ≥ 10% of amount); global xpubs on multisig PSBTs; signed PSBTs must have the draft's txid; finalize refuses with missing signatures |
| Wallet / key import | `core/src/interop/{mod,coldcard,bsms,sparrow}.rs` | Setup files can't swap keys silently: key count must match Policy, BSMS first address is checked, every key is shown in the review step before saving |
| Sync, fees, broadcast | `core/src/chain/electrum.rs`, `core/src/lib.rs` (async block) | Server URL is user-supplied only; fee estimates floored at relay fee; broadcast only after `finalize` |
| Hardware devices | `core/src/hwi/*.rs` | Address display: the device's address is compared with ours (`AddressMismatch`); device PSBTs are txid-checked; Trezor input/output acks (multisig redeem info, change detection only on the change chain); passphrase entry uses the advertised on-device capability or a transient host form, with explicit standard-wallet selection |
| UI | `macos/Northvault/Views/{SendView,SignTransactionSheet,ReceiveView}.swift` | What the user sees matches what is signed: outputs, change and fee shown before signing; broadcast needs confirmation; "Verify on device" result shown |

## Invariants

- [ ] No private key or seed is accepted, stored, logged or sent anywhere. Trezor host passphrases are sent only to the selected device, never persisted or logged.
- [ ] Every address shown for receiving comes from the stored descriptor (BDK `peek_address`).
- [ ] Every address paid is parsed with `parse_recipient` (checksum + network).
- [ ] Every signed PSBT, from USB, file or QR, passes the txid check before it is combined.
- [ ] Change outputs are recognized from the wallet's own descriptor, not from the PSBT alone.
- [ ] Addresses, xpubs and PSBTs are not written to logs.
- [ ] No credentials or server addresses are hardcoded. The Electrum URL comes from Settings.
- [ ] Network calls go only to the user's Electrum server, plus Blockstream's PIN server when a Jade is unlocked.

## Tests that cover these

`make test` currently passes 40 core tests, ten offline Regtest integration
tests and three descriptor C ABI integration tests. The live-node test remains
explicitly ignored pending the Bitcoin Core/electrs prerequisites. Checks include:

- BIP84/BIP86/BIP49 spec vectors (`wallet::descriptor::tests`)
- xprv and wrong-network rejection, path-depth check, SLIP-132 normalization
- Coldcard setup file, BSMS (with tamper check), Sparrow descriptor and BIP329 round trips
- Coin control uses only the selected inputs; preview drafts don't burn change addresses
- Fee rate refusal; 2-of-3 PSBT: one signature can't finalize, a mismatched PSBT is refused, two signatures finalize
- Multisig key order matches the script, which Coldcard and Trezor depend on (`hwi::util::tests`)

Not covered by automated tests: real device communication (Coldcard, Jade and Trezor
were not available while this was written) and Electrum sync against a live server.
The Trezor protocol code runs against Trezor's firmware emulator in
`make docker-test-hardware` (see TESTING.md). That needs the test-only Cargo
feature `emulator`, which must never be enabled in an app or release build: it
lets `hwi/trezor.rs` list a local UDP emulator as a device.
See "Verification" in DEVELOPMENT.md.

The persistence failure tests in `core/tests/regtest_persistence.rs` exercise the
legacy watch-only registry and labels through `WalletService`, with real temporary
SQLite files. Review `create_wallet`, `rename_wallet`, `delete_wallet`,
`import_labels` and `LiveAccount::set_label`: candidate state must be fully parsed
and saved before it becomes visible to callers. The account mutex spans validation,
save and publication. Errors must preserve account order, names and labels, and
a later unrelated write must not commit a rejected import's prefix. The tests
reproduce failures at both temporary writing and destination replacement and
verify retry/reopening. This does not add cross-process locking, power-loss
durability, or guaranteed deletion of leftover files to the legacy store.
The native wallet suite also edits Rename's AppKit text field and activates its
real submit control under a forced write failure, then reopens the editor and
retries successfully. It checks the visible error, unchanged live name on failure,
panel dismissal/model refresh on success, and persistence through a separately
opened Regtest service. Other UI actions still need equivalent interaction tests.

Hardware worker regression checks also cover thread affinity across concurrent
callers, idle periods and Tokio runtime teardown, and survival after a Rust panic.
Review `core/src/hwi/worker.rs` and ensure all synchronous device calls use it.
The worker cannot catch a native SIGTRAP; it prevents the suspected stale-run-loop
condition shown in `crash.log`. Verify repeated scans and unplug/replug after more
than a minute idle with real devices before considering the reported crash resolved.


## Trezor PIN matrix

Review `core/src/pin.rs`, the `PinMatrixRequest` branch in `core/src/hwi/trezor.rs`,
and `macos/Northvault/Support/TrezorPinHandler.swift`. The callback runs from the
persistent hardware worker and presents a borderless AppKit modal overlay on the
main thread. Its translucent child window covers the entire parent, including
toolbar and sidebar; the modal event loop blocks other app windows. Outside clicks,
Escape, parent-window closure and timeout cancel; ordinary app keyboard shortcuts
are consumed. Matrix buttons and keyboard positions use the same bottom-up mapping.
Review `PinMatrixEntry` for length/range limits, one-shot submission and cancellation
that discards partial input. The overlay restores the parent after dismissal.
Only current-PIN requests are accepted. Cancel/timeout sends the protocol Cancel;
incorrect PINs are not automatically retried. Matrix positions are transient, not
persisted. `tracing` max-level features suppress upstream protobuf TRACE logs in
both debug and release builds. Do not remove that restriction.

Tests cover matrix validation, compile-time logging suppression, PIN acknowledgement
on the original transport, cancellation, PIN-change rejection and wrong-PIN failure.
Physical-device acceptance, cancellation and retry still require manual verification.

Address verification offers every detected device, prioritizing matching discovery
fingerprints. Locked devices may have no fingerprint, and cached fingerprints can
refer to another passphrase wallet. Neither is an authorization decision: the
Rust `device_verify_address` comparison remains mandatory. `scripts/test-panels.sh`
checks device selection through Swift/UniFFI with a real synthetic wallet and
temporary persistence. Actual address display/unlock still needs hardware checks.


## Trezor passphrase compatibility

The credential callback also handles host passphrases for Model One and other devices
without `Capability_PassphraseEntry`. Modern capable devices get `on_device=true`;
legacy `_on_device` requests get an empty acknowledgement. The host form requires
an explicit choice of standard wallet or matching masked passphrase fields. Cancel
sends Cancel, never an empty passphrase. Exact UTF-8 input is preserved. TRACE/DEBUG
logging remains compiled out. Review the new `PassphraseRequest` branch and UI fields;
validate the chosen wallet fingerprint/addresses on a physical device. Tests cover
capability selection, legacy acknowledgement, exact/empty input, length and cancellation.


## In-panel credential navigation

`RightPanel.swift` keeps previous pages mounted while a child page is active, disables
hidden pages, and calls close callbacks once in child-first order. Passphrase entry
uses a one-shot `NSCondition` response so the hardware worker waits while the main
thread remains available for in-panel navigation. Closing its page or a parent,
switching accounts, window closure, or timeout resolves cancellation; a submitted
empty string remains an explicit standard-wallet selection. `scripts/test-panels.sh`
checks these cancellation semantics without device access or real credentials.

## Encrypted storage review boundary

The new `descriptor-core/` and `shared/` code, Apple entitlements, and storage build
scripts require independent review before production use. In particular review:
AAD framing and slot-manifest authentication; independent per-wallet keys;
BIP-85 retention/synchronization and scope; Keychain deletion propagation; untrusted
metadata versus authenticated payloads; file conflict and rollback handling;
legacy plaintext preservation; and physical signed-device acceptance in DEVELOPMENT.md.
No direct hardware BIP-85 extraction or cross-device validation is claimed.

`RecoveryChecks.swift` now exercises Regtest storage failures through the real
repository, CryptoKit and descriptor ABI: destination-save/source-delete failures
must retain recoverable key copies; rotation needs every retained signer and
invalidates the old DEK; stale writes and altered offline snapshots must preserve
conflicting content. Structurally valid envelope metadata substitutions are tested
separately from parse failures. File coordination is substituted only in tests;
an injected coordinator failure confirms no uncoordinated fallback occurs.

`KeychainAdapterChecks.swift` exercises the production Apple adapter with only the
four Security.framework calls substituted. Its internal test initializer is not
available through app preferences; public construction always uses the real OS.
Tests check query scoping, accessibility, CRUD/status propagation, recovery and
concurrent isolation. A reproduced malformed-success result previously became
`keychain(0)` or silently omitted recovery records. It now fails with `errSecDecode`.
Real entitlements and synchronized Keychain behavior still need device acceptance.

`VaultModelChecks.swift` uses temporary Regtest storage and isolated preferences,
Keychain, authentication and cloud-directory boundaries. Locking while device
authentication awaited was reproduced revealing decrypted data after the lock.
The same risk existed while repository recovery or edits awaited external work.
`VaultModel.lock()` now invalidates an access generation; async publishers check
it before revealing data or continuing follow-up work. Tests suspend authentication
and Keychain reads/writes to verify lock wins over late completion, including
automatic recovery, creation, slot edits and queued actions. Already-started
encrypted writes may finish and remain recoverable, but cannot repopulate the
locked view. This is a UI disclosure invariant, not cancellation of committed
storage operations, memory zeroization, or a replacement for device authentication.

The model boundary tests also reproduce an invalid signer selection rotating the
wallet instead of failing. A picker may retain a stale index when switching
wallets. Slot actions now validate the current wallet's cosigner bounds before
indexing or mutating; removing with rotation also requires an existing slot.
Creation validates that each supplied recovery secret has a corresponding BIP-85
index. Invalid selections/indices must preserve both ciphertext and Keychain
material; the maximum permitted BIP-85 index is tested through actual slot creation.
The macOS rendering workflow hosts the real vault view with synthetic Regtest
data, captures native controls, and independently checks displayed text with
Tesseract. It verifies name/policy disclosure only while unlocked and restoration
after explicit recovery. Model-driven snapshots do not establish interactive
input, VoiceOver, device authentication, or iOS rendering acceptance.

The multisig setup uses `MultisigPolicySlider.swift` to keep 1 ≤ M ≤ N and
1 ≤ N ≤ 15. A total of one key selects single signature; larger totals select
multisig, with a compatible script type and threshold clamped to the key count.
`scripts/test-panels.sh` exercises both type transitions and selected policies through actual
Swift/UniFFI wallet preview, creation, export and import with synthetic keys, plus
PIN entry limits/completion and full-workspace panel navigation. The isolated
preview provides PIN overlay and timeout checks without invoking a hardware device.
Physical PIN acceptance and disconnect behavior still require a real Trezor.

## Branded QR generation and scanning

`QRCodeRenderer`, `QRImageDecoder`, `QRCodePresentation`, and `QRCodeOverlay` share
one path for Receive and unsigned transaction QR export. The image library is a
documented local subset of EFQRCode 6.2.2. Its CoreImage pixel extraction was replaced
with the pinned Arase encoder from qrcode-terminal 0.12.0 after reproducing nil
CoreImage raster output. Review both `vendor/` provenance files and licenses.
JavaScriptCore receives bounded UTF-8 bytes as arguments, never source code; it has
no exposed host, filesystem, network, or console objects. Each context is transient.

CoreGraphics embeds the supplied shield at 14% of QR width with high correction.
Every finished frame is decoded with Vision's CPU revision-1 QR detector using a
CPU-backed luma buffer, avoiding reproduced CoreImage/IOSurface/ANE failures. A
mismatch or render/decode failure produces an explicit error; never a blank or
unbranded fallback. Bounds apply to bytes, frame count, dimensions and retained
bitmap memory. Cancelling stops preparation/animation and releases the frames.
Preparation starts in a detached task; completion is delivered through the modal
run loop with a generation token. A task inherited from MainActor was reproduced
stalling when the main queue entered that loop. The panel suite waits inside the
modal mode without yielding the queue, and checks cancellation of queued results.
No wallet payload is logged. The overlay blocks other app actions until dismissal;
PIN credential collection and timeout semantics are unchanged.
QR outside-click dismissal uses a native mouse-down monitor and the card's live
AppKit bounds, rather than a SwiftUI gesture queued behind the modal action. The
closing event is consumed so it cannot activate the underlying wallet. Inside
clicks remain in the card; Escape and the accessible backdrop action also close it.

The integration test exposed and fixes two existing `interop/ur.rs` decoder errors:
base64 input must retain its case, and CBOR byte-string prefixes 0x58/0x59 must not
be mistaken for base64 based on their ASCII letters. Non-UR PSBTs are now parsed
before storage as binary. UR payloads are unwrapped as CBOR. Existing signing/draft
identity checks and explicit broadcast confirmation remain in force.

`scripts/test-qr.sh` exercises real EFQRCode/Arase → rendered logo → Vision → Rust
UR decoding with synthetic PSBTs, including displayed image size, exact payload
comparison, and invalid inputs. Rust tests cover base64, single/multipart UR,
reversed fragments and incomplete/invalid scans. Panel tests cover asynchronous
preparation, cancellation and error display state. These do not establish physical
camera performance or an independent audit; retain real-device QR acceptance checks.

## Disposable Docker Regtest harness (2026-11-02)

`compose.yaml` adds an internal-only Bitcoin Core/electrs stack and a portable Rust
test runner. No host ports, wallet directories, devices, or Docker socket are
exposed. Unprivileged services share a network namespace to preserve the live
test's loopback-only RPC/Electrum assumptions; cookie readers mount node data
read-only. Dedicated named volumes hold only synthetic Regtest state. Bootstrap
requires the fixture marker and RPC Regtest identity; the Rust test independently
checks Electrum genesis before spending. Dependencies are fetched at build time;
tests execute offline. Bitcoin archives are SHA-256 pinned and electrs is pinned
to a source commit/lockfile. Base image tags and apt packages are not digest locked.

The bootstrap/readiness fixture checks are written for first startup, repeated startup,
wallet reload, refusing unmarked/wrong-network nodes, immature miner readiness,
index lag, invalid RPC responses, and a ready index. These substitute RPC and
exercise a real local TCP boundary; they do not establish Core/electrs compatibility.
On 2026-11-02 the Colima/arm64 stack built and passed all three Python checks and
42 Rust tests, including live Core mempool acceptance for all seven scripts, in
two consecutive runs on the same chain. Verification found two harness defects:
parent-directory Docker ignore exceptions included host build outputs, and fixed
test keys rediscovered prior transactions. Explicit source copies/ignore rules
now restrict build inputs; live fixtures derive fresh, deliberately public test
seeds from a newly allocated miner address. This seed constructor remains inside
the integration-test support module; no production signing API changed.

Native `make test` passes 53 tests; Clippy passes with six existing map-or warnings.
Changed Rust files pass rustfmt; repository-wide formatting still fails in older
code. The Linux suite omits hardware features and all native Apple tests; see
`docker/README.md` and `TESTING.md` for exact commands and remaining scope.

The separate coverage image uses pinned cargo-llvm-cov 0.9.1 and Rust 1.94.0 LLVM
tools. It instruments only integration-test suites (including live Regtest), with
no new production features or signing surface. Reports are written solely to
`build/coverage-rust`, the coverage runner's additional host mount. The first
completed run (`run.3vhsXD`) passes 14 integration tests and measures 1,349/1,974
Rust lines (68.34%), with seven source files absent. The strict gate returns 1;
hardware-disabled/absent files and separate Apple coverage remain explicit.

The next portable run (`run.Kz0U3c`) passes 21 integration tests and measures
1,788/1,980 lines (90.30%). The immediate gate is now 80% of measured lines;
missing files remain listed and the optional 100% inventory gate stays strict.
Service-level regression tests reproduced preview fee-validation and arithmetic
overflow defects. The preview backend now shares the production fee validator
and uses checked addition for quoted totals and receive offsets. It remains
read-only, cannot sign or broadcast, and has no new secret handling. The live
Regtest suite verifies chart/label persistence, drain accounting, and fee warnings.

Native coverage now permits an initial constrained policy in the internal setup
view and an initial directory in the internal file browser. Defaults retain the
existing one-key policy and home directory; tests supply only synthetic policy
and temporary storage. Credential view types are internal so the native runner
can test their real bindings and replies without calling a device. Credential
limits, byte preservation, one-shot replies and cancellation semantics are unchanged.
The runner does not establish destructive file replacement, slider dragging,
modal window routing, OS Keychain/iCloud, or physical-device acceptance.

Final measured Swift report `run.lz0592` passes the 80% gate: 7,136/8,831 lines
(80.81%), up from 64.78%. Both app entry points remain absent. `make build`,
69 storage workflows, panel checks, 37 QR checks and the expanded native wallet
UI suite pass. The native setup rejects malformed keys, preserves review/account
state on a registry-write failure, and succeeds after the fault is removed.
The report is scoped to instrumented sources and is not a security audit.
