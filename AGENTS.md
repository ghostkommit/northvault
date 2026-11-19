# AGENTS.md

Guidance for coding agents working anywhere in Northvault. Keep changes small,
complete, reviewable, and safe for a Bitcoin wallet.

## Project context

Northvault is a watch-only Bitcoin wallet for macOS: SwiftUI presents the UI,
Rust/BDK implements wallet logic, and UniFFI connects them. Coldcard, Trezor, and
Jade perform transaction signing. The shared macOS/iOS descriptor manager adds
encrypted backups and recovery; it does not authorize spending.

Read [README.md](README.md) for what the app does and
[DEVELOPMENT.md](DEVELOPMENT.md) for workflows. Before changing wallet, hardware,
cryptography, storage, or permissions code, also read [SECURITY.md](SECURITY.md),
[ARCHITECTURE.md](ARCHITECTURE.md), and the relevant parts of [REVIEW.md](REVIEW.md).
These describe existing limitations, not evidence of a completed security audit.

| Location | Responsibility |
| --- | --- |
| `core/src/wallet/`, `core/src/interop/` | Descriptors, addresses, transactions, PSBTs, interchange formats |
| `core/src/chain/`, `core/src/store/` | Electrum, synchronization, legacy local persistence |
| `core/src/hwi/`, `core/src/pin.rs` | Hardware transports, worker thread, credential callbacks |
| `descriptor-core/` | Public descriptor validation with Miniscript and a C ABI |
| `shared/Sources/WalletModels/`, `WalletCrypto/`, `WalletStorage/`, `WalletUI/` | Models, encrypted envelopes, Keychain/files, shared UI; all under `shared/Sources/` |
| `macos/Northvault/` | Full wallet app, navigation, presentation, app state |
| `apple/`, `ios/`, `scripts/`, `Makefile` | Apple targets/entitlements, storage client, builds and checks |

## Working principles

**Load the `ponytail` skill before any implementation work** (writing, fixing,
refactoring, reviewing, choosing dependencies) and keep it active for the session
at its default `full` level. If the skill is unavailable, follow the
[upstream rule](https://github.com/DietrichGebert/ponytail/blob/main/.agents/rules/ponytail.md);
the principles below restate it for this wallet and win where they are stricter.

Apply Karpathy's four principles with Ponytail's smallest-complete-change approach:

1. **Think before coding.** Read the affected code and search its callers first.
   State material assumptions and tradeoffs. Identify effects on users, persisted
   data, public interfaces, tests, fixtures, configuration, and exports. Use sound
   defaults for reversible details; ask when ambiguity changes fund safety,
   recovery, privacy, or the requested behavior. Continue independent work.
2. **Simplicity first.** Take the first option that fully solves the problem:
   omit an unnecessary feature; reuse the project's existing helper or pattern;
   use the standard library/platform; use an installed dependency; write a clear
   one-liner; otherwise write the minimum readable implementation. Do not add
   speculative abstractions, knobs, wrappers, dependencies, or future-proofing.
3. **Surgical changes.** Every edit should serve the task. Match surrounding
   conventions, preserve unrelated user changes, and remove only dead code your
   change creates. Fix a shared root cause once and update every affected caller.
   Preserve validation and error handling when moving or consolidating code.
4. **Goal-driven execution.** Define observable success criteria, make the change,
   and verify them. For a behavioral bug, add an integration regression test.
   Finish required callers, fixtures, documentation, and generated interfaces.
   Report actual results, unperformed checks, and material limitations.

Prefer deletion and straightforward code, but never trade away boundary
validation, fund safety, recovery, accessibility, or required hardware behavior
to shorten a diff. Comment on non-obvious reasons and invariants. Record a
deliberate shortcut's limit and the condition that requires replacing it.

## Wallet security invariants

### Keys, secrets, and privacy

- Keep transaction signing on hardware. Production code must not accept, derive,
  persist, or export seed phrases, xprvs/tprvs, or signing private keys. Synthetic
  private keys belong only in clearly isolated tests/fixtures, never production
  defaults or wallets used for funds.
- Watch-only does not mean secret-free: BIP-85 HEX outputs, DEKs, hardware PIN
  matrix responses, and passphrases are sensitive. Keep BIP-85 secrets and cached
  DEKs in the existing Keychain design. Keep device credentials transient.
- Never log secrets, descriptors, xpubs, addresses, PSBTs, wallet payloads, or
  identifying wallet metadata. Check error formatting, `Debug`/`description`,
  tracing instrumentation, crash reporting, and upstream library logs too.
  Preserve the compile-time TRACE/DEBUG suppression protecting Trezor messages.
- Never use real wallet data, Keychain entries, credentials, or production
  backups for tests. Do not upload them to external tools or issue trackers.
  Use synthetic fixtures and temporary storage.
- Preserve separate explicit opt-ins for signer-secret and DEK synchronization
  through iCloud Keychain. Neither belongs in iCloud Drive, preferences, source,
  filenames, or plaintext metadata. Do not claim guaranteed memory zeroization
  across Swift, UniFFI, or system frameworks.

### Descriptors, addresses, and transactions

- Use BDK, Miniscript, and established Bitcoin types; do not invent cryptography,
  address parsers, descriptor rewrites, or signature verification algorithms.
  Parse untrusted input into types that encode validated invariants.
- Validate checksum, explicit network, derivation path/origin, script policy,
  threshold, and key count at import boundaries. Test networks can share key
  encodings; do not infer the exact network from an xpub prefix alone. Reject
  unsupported policies rather than silently substituting another script.
- Preserve receive/change branches and key ordering (`multi` and `sortedmulti`
  have different semantics). Derive receive addresses from the stored descriptor;
  verify returned device addresses against the independently derived address.
- Represent Bitcoin amounts in integer satoshis with checked arithmetic. Keep
  display/fiat conversions separate from spend calculations. Validate fee rates
  for finiteness, sign, bounds, and explicit units; preserve existing fee caps,
  warnings, coin-control selection, and dust handling.
- Treat every PSBT from USB, file, or QR as untrusted. Preserve the unsigned-draft
  transaction identity check before combining signatures, and validate relevant
  input/output, UTXO, fee, and sighash data. A matching txid alone does not
  authenticate all PSBT metadata. Recognize change from our wallet descriptor,
  not an import's labels or derivation claims.
- Show the actual recipients, amounts, change, and fee being signed. Invalidate
  a stale review if the draft changes. Preserve hardware confirmation, complete
  signature/finalization checks, and explicit user confirmation before broadcast.
  An encrypted-descriptor unlock is never authorization to sign or broadcast.

### Hardware and asynchronous behavior

- Keep synchronous Coldcard/Trezor discovery and calls on the persistent hardware
  worker. macOS HIDAPI depends on thread/run-loop lifetime; do not move these
  calls onto Tokio's temporary blocking pool.
- Prefer on-device passphrase entry when supported. Preserve exact host-entered
  UTF-8; never trim or normalize a passphrase. An explicit standard-wallet choice
  may submit an empty passphrase; Cancel must never do so.
- Preserve one-shot completion and cancellation on timeout, Back, account change,
  window closure, and disconnect. Do not automatically retry incorrect PINs or
  signing requests. Keep UI updates on the main thread and blocking device work
  off it; stale results must not affect a different account or draft.

### Encryption, persistence, and recovery

- Follow the versioned envelope/AAD specification in `ARCHITECTURE.md`. Preserve
  CryptoKit AES-256-GCM, HKDF domain separation, secure randomness, fresh nonces,
  independent per-wallet DEKs, and authentication of the complete slot manifest.
  Never use a public identifier or xpub as an encryption secret.
- Authenticate before displaying or acting on decrypted payloads. Fingerprints,
  UUIDs, filenames, and public envelope fields are discovery hints, not proof of
  signer identity or authorization. Keep input/file/slot limits; reject unknown
  versions, algorithms, malformed lengths, duplicate slots, and failed tags.
- Descriptor recovery may use any one authorized slot even for a multisig wallet.
  This must not alter the transaction-signing threshold. Removing a recovery slot
  does not revoke an already learned DEK. Rotation needs a fresh DEK and every
  retained signer's secret; old backups remain decryptable with old keys.
- Fail closed on authentication, Keychain, entropy, and coordinated-write errors.
  Do not fall back to plaintext, weaker Keychain accessibility, uncoordinated
  production writes, disabled TLS validation, or silently dropped recovery slots.
- Preserve coordinated writes, previous valid ciphertext, conflict copies, and
  rollback checks. Do not silently overwrite divergent revisions or delete
  duplicates. Design format/schema migrations for interruption and recovery;
  never reinterpret existing ciphertext under changed encoding rules.
- Keep legacy plaintext wallet files distinct from encrypted storage. Creating
  an encrypted backup does not erase those files or justify uploading them.
  Clearing local access must not delete shared recovery secrets for other wallets.

## Trust boundaries and security review

Adapt the trust-model approach from Alpen to this wallet; do not inherit its
trusted-node assumptions. Imported files/QR, PSBTs, hardware responses, Electrum
responses, clipboard data, cloud/shared-folder files, and unauthenticated local
envelopes are untrusted. A configured server or connected device is not authority
to change wallet policy, classify change, redirect funds, or bypass checks.

Keep network access within documented, user-configured workflows. Do not add
telemetry, third-party address lookups, implicit server failover, or broader cloud
discovery: these can expose wallet ownership and transaction history. Preserve
TLS verification and the separation between the storage-only client and the
legacy blockchain backend.

For a security finding, identify the attacker, controlled input, crossed boundary,
reachable code path, impact, and a synthetic reproducer/test. Distinguish a
security flaw from a correctness defect or documented limitation. Do not dismiss
fund redirection, secret exposure, or recovery-data loss merely because the input
is local. Avoid duplicate reports of known limitations unless new evidence changes
their impact. Keep exploit details and real user data out of public reports.

Changes to spending, derivation, device protocols, cryptography, recovery, FFI
ownership, dependencies, or Apple entitlements require particular review care.
Document the invariant affected and its verification; preserve/update existing
`SECURITY-SENSITIVE` notes and `REVIEW.md` when the review boundary changes.
Automated success is not an independent audit or physical-device acceptance.

## Build and verification

### Integration coverage rule

The current milestone is **80% measured code coverage**, reported separately for
Rust and Swift with uninstrumented sources and hardware/OS gaps listed explicitly.
Prefer integration tests to reach that milestone. The longer-term target remains
**100% integration test coverage of supported behaviors**. Every supported
workflow and every new or changed behavior must have an integration test covering
its successful outcome and relevant failure, boundary, and recovery paths. This
is a behavioral coverage requirement, not a claim that current coverage is 100%
or that a line-coverage percentage proves correctness.

Prefer integration tests over isolated unit tests. Exercise real cooperating
modules through public interfaces, including parsing, cryptography, persistence,
and FFI where relevant. Use synthetic data and temporary storage; substitute only
external boundaries such as hardware devices, remote servers, and OS services
when needed for deterministic tests. Unit tests supplement integration coverage
for precise algorithms or difficult edge cases; they do not replace it.

Map each changed behavior to its integration test and report uncovered or skipped
paths explicitly. A mocked boundary does not establish coverage of the real
device/service: retain the physical-device acceptance checks below. Do not claim
full coverage while those paths remain unverified. Documentation-only changes
and edits that do not change behavior need no new tests.

### Commands and acceptance checks

Use the pinned Rust toolchains and lockfiles. These are separate Cargo crates,
not a root Cargo workspace. Run checks appropriate to the change from the repo root:

| Change | Check |
| --- | --- |
| Rust wallet logic | `make test` |
| Trezor transport or signing (`core/src/hwi/trezor.rs`) | `make docker-test-hardware` (firmware emulator; not device acceptance) |
| Descriptor validation | `(cd descriptor-core && cargo test --locked)` |
| Shared crypto/storage/descriptor bridge | `make storage-test` |
| Full macOS app or Swift/Rust interface | `make build` |
| Panel navigation or credential cancellation | `make build` then `bash scripts/test-panels.sh` |
| QR generation, logo embedding, or scan payloads | `make build` then `bash scripts/test-qr.sh`; retain physical camera/device checks |
| Storage-only macOS client | `make storage-build-local` |
| XCFramework / Apple target setup | `make core` / `make storage-apple` (full Xcode required) |

For Rust changes, enter each affected crate directory so rustup selects its
`rust-toolchain.toml`, then run `cargo fmt -- --check` and appropriate
`cargo clippy --locked --all-targets` checks. For hardware-feature changes, also
run `(cd core && cargo check --locked --no-default-features)` from the repo root.
Report pre-existing failures separately; do not reformat unrelated files.

Regenerate UniFFI bindings through the build scripts after Rust API changes;
`make build` supports Command Line Tools, while `make core` packages an
XCFramework with full Xcode. Edit XcodeGen specifications, not generated projects.
Do not hand-edit `macos/Generated/` or build artifacts. Preserve C ABI ownership,
buffer bounds, matching frees, and panic containment at the Rust/Swift boundary.

Use focused tests for behavior and negative cases: wrong network, substituted
PSBTs/change, missing signatures, malformed imports, tampered envelopes, wrong
secrets, cancellation, and interrupted/conflicting writes. Keep tests offline and
isolated by default. Do not weaken a security assertion to make a test pass.

`make storage-test` uses real CryptoKit/Miniscript with a test coordinator and
in-memory Keychain. It cannot prove real Keychain/iCloud propagation, entitlements,
biometrics, or hardware signing. Follow the DEVELOPMENT.md physical-device checks with
synthetic wallets and test networks when those behaviors change; report checks
that could not run. Do not operate a user's real wallet or broadcast as a routine
development check.

## Change hygiene

Keep dependency additions/upgrades narrowly scoped; inspect provenance, features,
build scripts, lockfile changes, and security implications. Preserve aligned FFI
and protobuf versions and logging restrictions. Never bypass sandbox, signing,
authentication, or transport protections to get a build or test passing.

Inspect the final diff when Git is available; this directory may be a local
exploration without `.git`. Do not initialize, publish, rewrite history, or remove
user files as an incidental setup step. Finish with what changed, what was
verified, and any remaining concrete risk or unperformed check.

## References

- [Karpathy-inspired coding principles](https://github.com/multica-ai/andrej-karpathy-skills)
- [Ponytail: smallest complete change](https://github.com/DietrichGebert/ponytail/blob/main/.agents/rules/ponytail.md)
- [Alpen AGENTS.md: trust-model-aware review](https://github.com/alpenlabs/alpen-ee/blob/main/AGENTS.md)

These are inspirations. The rules above are adapted to Northvault's architecture
and security boundaries; upstream examples are not additional project commands.
