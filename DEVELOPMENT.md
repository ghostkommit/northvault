# Developing Northvault

Build, test and architecture notes for contributors. For what the app does and how to
install it, see [README.md](README.md). Security-sensitive areas are listed in
[REVIEW.md](REVIEW.md); coverage and test workflows are in [TESTING.md](TESTING.md).

> This code was written with AI assistance and has not had an independent security
> audit. It needs normal human review before changes are merged.

## Quick reference

```sh
make help            # list every target
make lint            # rustfmt, clippy, shellcheck, SwiftLint, actionlint (those installed)
make test            # Rust unit and offline Regtest integration tests
make build           # local ad-hoc signed app (Command Line Tools are enough)
make storage-test    # shared encryption/storage checks (needs Tesseract 5)
make coverage        # offline Rust integration coverage with the critical-file gate
make dist            # zip the app with a SHA-256 checksum into dist/
```

CI (`.github/workflows/ci.yml`) runs lint, both Rust suites, the Docker Regtest
coverage gate, and the macOS build with the storage, panel and QR suites on every
push and pull request. The OCR-driven wallet UI suite and the Swift coverage gate
need Retina text rendering and run locally: `make coverage-swift-check`. Pushing a `v*` tag builds the app on a GitHub macOS runner and
publishes the zip and its checksum as a GitHub release
(`.github/workflows/release.yml`).

## Why this stack

| Layer | Choice | Reason |
|---|---|---|
| UI | SwiftUI (macOS 14+), Swift Charts, `Table`, `NavigationSplitView` | Native controls: sidebar, toolbar, Settings panel (⌘,), multi-select tables, VoiceOver, keyboard navigation |
| Core | Rust crate `northvault-core` with [BDK](https://bitcoindevkit.org) | Bitcoin logic lives in one memory-safe place |
| Bridge | UniFFI 0.28 (proc-macros) | Generates Swift types from Rust automatically. Same approach as `bdk-swift` |

Alternatives considered: Tauri (web UI, not native), Slint/egui/Iced (Rust UI, non-native look and controls).

## Build

For portable Rust and live Bitcoin Regtest tests with **only Docker installed**,
run from this directory:

```sh
docker compose run --build --rm tests
```

This starts disposable Bitcoin Core and electrs services, waits for readiness,
and runs singlesig/multisig receive/sign/send integration workflows. See
[docker/README.md](docker/README.md) for lifecycle commands, isolation, and current
verification limitations. Native Apple UI/storage tests still require macOS tools.

Requirements: **Xcode 15+**, Rust via rustup (the toolchain is pinned in
`core/rust-toolchain.toml` and installs itself), `brew install xcodegen`.

```sh
make test     # Rust tests plus offline Regtest integration workflows
make open     # build core for arm64 + x86_64, generate bindings + Xcode project, open it
```

Then run the `Northvault` scheme. After changing the Rust API, run `make core` again.

With only Apple's Command Line Tools installed, use `make build` to build the universal
Rust library, generate bindings, and package the Swift app for the host architecture.
Launch it with `open macos/build/Northvault.app`, or use `make run` to build and launch.
Run `make wallet-ui-test` for native screen checks using disposable Regtest wallets
and the test-only software signer fixtures (requires Tesseract 5). Run
`make coverage-swift` to measure the four Swift integration suites.
`make coverage-swift-check` and `make coverage-rust-check` enforce the current
80% measured-line milestone while listing missing sources; see
[TESTING.md](TESTING.md) for current coverage, live Regtest setup and remaining gaps.
The bundle includes camera permission metadata and an ad-hoc signature for local use;
use Xcode with a developer signing identity for distribution. Launch the `.app` bundle,
not the bare executable produced by older versions of this build script.
`make core` requires full Xcode for XCFramework packaging and reports that requirement
before starting work. Cargo commands use the checked-in lockfile.

Mainnet defaults to Blockstream's public server (`ssl://electrum.blockstream.info:50002`).
Open Settings (⌘,) to change the server address (`ssl://host:50002`) or network,
then **Add account**. Existing custom addresses are preserved; other networks require
their own server. "Show sample wallet" in Settings switches to
read-only demo data for design review.

Transaction history comes from the configured Electrum server after importing the
device's account key. USB connection alone does not download history. Sync scans
receive and change addresses with a gap limit of 20 and also checks previously
revealed addresses. Fee-estimation failures do not discard downloaded history.
The discovery regression test uses an in-memory Electrum connection to verify
confirmed receipts, pending spends/change, and persistence after reopening.

## Layout

```
core/                              Rust
  src/lib.rs                       WalletService: the whole API the UI uses (sample or live backend)
  src/models.rs                    Types shared with Swift
  src/mock.rs                      Sample data for previews and design review
  src/wallet/descriptor.rs  ⚠      Build/parse descriptors, standard default paths, SLIP-132
  src/wallet/address.rs     ⚠      Recipient address parsing (checksum + network)
  src/wallet/live.rs               BDK wallet + SQLite per account → UI types
  src/wallet/tx.rs          ⚠      PSBT building, coin control, fee checks, combine, finalize
  src/chain/electrum.rs     ⚠      Sync, fee estimates, broadcast
  src/chain/price.rs               Price/FX source (sample only, see below)
  src/interop/              ⚠      Output descriptors, Coldcard files, BSMS, BIP329, PSBT files, BC-UR QR
  src/hwi/                  ⚠      Coldcard, Jade, Trezor over USB
  src/store/                       wallets.json registry, per-wallet SQLite and labels
macos/
  project.yml                      XcodeGen spec (frameworks, camera usage, entitlements)
  Northvault/
    NorthvaultApp.swift            Window and menu commands
    Support/Theme.swift            Design tokens (colors, radii, spacing, fonts)
    Support/AppState.swift         Navigation, settings, sync and device state
    Support/Money.swift            Currency / unit / hide-balances formatting
    Support/FilePanels.swift       In-panel file browser and export
    Views/…                        One file per screen
  Generated/                       Swift bindings (created by `make core`, not committed)
scripts/build-core.sh              Universal static lib → bindings → XCFramework
```

⚠ = security-sensitive, see [REVIEW.md](REVIEW.md).

## Right-panel navigation

Account setup/details, signing, QR scanning, settings, label/name edits,
confirmations and file import/export open in the right-hand detail panel. **Back**
returns to the previous page while preserving its form state for nested workflows.
Settings and account actions (wallet details, export/import labels, rename,
registration and removal) use the window title instead of a separate panel heading
and Back button. Account actions share Receive's card surface. Clicking an account
in the sidebar, including the already-selected account, closes panels and returns
to its Transactions page. Switching account actions replaces the previous action.
General messages appear
as dismissible banners. File exports ask for overwrite confirmation inline.

QR display and the Trezor PIN matrix use translucent, application-modal overlays covering the
whole wallet window, including its sidebar and toolbar. Click outside the PIN box
or press Escape to cancel; other wallet actions are blocked until it closes. The wallet passphrase form lives
in the right panel; Back, Cancel, switching accounts or closing the window cancels its
pending device request. It also expires after five minutes. Native macOS permission
prompts (such as camera access) remain controlled by the operating system.

After `make build`, run `bash scripts/test-panels.sh` to check nested-page cancellation
and the distinction between cancelling a passphrase and choosing the standard wallet.

## New-account defaults

The three-step wizard fills the right workspace, with scrollable content and its
actions at the bottom. Fields, key rows and the policy slider expand with the workspace.
It starts at 1-of-1 with single-signature native SegWit (BIP84, account 0).
The slider alone decides wallet type: one key is single signature, and two or more
keys are multisig. Crossing that boundary selects the appropriate native SegWit
script; other compatible script selections are preserved.
A single policy track has two handles: required signatures above and total keys
below. Drag them, use focused arrow keys, or accessibility increment/decrement
actions. It supports 1 through N signatures and 1–15 keys, always keeping M ≤ N.
A single connected USB device supplies the suggested account name. Otherwise a small
northern-landscape word list generates names such as “Aurora Harbor”; the dice button
suggests another. Existing names get a numeric suffix, and typed names are preserved.

On the keys step, one connected device is read automatically for the selected script
type. PIN/passphrase/device approval still happens normally. With multiple devices,
the picker preselects one and **Read key** starts the request explicitly. Failed reads
are not retried automatically. Back/Continue preserves keys when the script type is
unchanged; changing the script type clears keys derived for the old path. File/xpub
import and final address review remain available.

## Design → code map

| Design | Code |
|---|---|
| Left sidebar: total portfolio + accounts | `SidebarView` (native `List(selection:)`) |
| Sidebar status: hardware device, Electrum server | `SidebarView` → `SidebarFooter` (click to scan / sync) |
| Total portfolio → chart only | `PortfolioView` → `NetWorthCard(accountId: nil)` |
| Top bar: Transactions · Send · Receive · Addresses · UTXOs | Segmented picker in the window toolbar (`ContentView`) |
| Net worth chart, ranges, hover tooltip | `NetWorthChart.swift` (Swift Charts + `onContinuousHover`) |
| Currency in settings | `SettingsView` (⌘,) → `AppState.currency`, persisted in `UserDefaults` |
| Hide balances | Settings → Privacy → `MoneyFormat.hidden` |
| UTXO checkboxes | Native table multi-select (click, ⌘-click, ⇧-click); "Send selected" = coin control in `SendView` |
| Branded QR | `QRCodeRenderer` → EFQRCode image embedding + local Arase encoder, verified with Vision |
| Inter / JetBrains Mono | SF Pro / SF Mono (system fonts) |
| Add account | `AddWalletSheet` (policy → keys → review) |
| Create transaction → sign | `SignTransactionSheet` (USB, SD-card PSBT, animated QR, camera scan) |
| Verify on device | `ReceiveView` → `deviceVerifyAddress` |
| Account actions (details, export, labels, register, rename, remove) | `AccountMenu` (toolbar) |
| Animated QR / QR scanner | `QRCodePresentation` / `QRCodeOverlay`, `QRScannerView` |
| Labels | Right-click → "Edit Label…" on transactions, addresses and UTXOs (`labelEditor` in `Components.swift`) |

All colors and sizes come from `Theme.swift`. To change the look, edit tokens, not views.

## Compatible formats

Northvault reads and writes standard interchange formats, so wallets move to and from
other descriptor wallets. It doesn't read another application's private wallet database.

| Format | Import | Export | Code |
|---|---|---|---|
| Output descriptor (BIP389 multipath; Bitcoin Core `/0/*` too) | ✓ | ✓ | `interop/descriptor_file.rs` |
| Multisig setup file (Coldcard, also Jade / Keystone / Passport) | ✓ | ✓ | `interop/coldcard.rs` |
| BSMS descriptor record (BIP129, unencrypted) | ✓ | ✓ | `interop/bsms.rs` |
| Specter DIY wallet file (`addwallet name&descriptor`) | ✓ | ✓ | `interop/descriptor_file.rs` |
| Coldcard keystore JSON (`coldcard-export.json`, `ccxp-*.json`), Cobo Vault / Keystone JSON | ✓ | – | `interop/coldcard.rs` |
| Jade / Keystone single-sig descriptor (`wpkh([fingerprint/path]xpub/0/*)`) | ✓ | – | `interop/mod.rs` |
| Key expression `[fingerprint/path]xpub` (any SLIP-132 form) | ✓ | – | `interop/mod.rs` |
| Labels (BIP329) | ✓ | ✓ | `interop/labels.rs` |
| PSBT file (binary or base64) | ✓ | ✓ (binary) | `interop/psbt_io.rs` |
| Animated QR PSBT (BC-UR `crypto-psbt`) | ✓ (camera) | ✓ | `interop/ur.rs` |
| Account key QR (BC-UR `crypto-account`, BCR-2020-015; or static `[fingerprint/path]xpub`) | ✓ (camera) | – | `interop/ur.rs` |
| Wallet descriptor QR (BC-UR `crypto-output`, BCR-2020-010; keys at `/0/*`, readers add change) | – | ✓ | `interop/ur.rs` |

Defaults follow the standards: BIP44/49/84/86 single-sig, BIP48 (`/1'` nested, `/2'` native) and BIP45
multisig, `sortedmulti`, change on `/1/*`, gap limit 20, RBF on.

## Hardware wallets

| | Coldcard | Jade | Trezor |
|---|---|---|---|
| Transport | USB (HID) via `coldcard` crate; SD-card PSBT | USB (serial) via `async-hwi`; animated QR | USB via `trezor-client` |
| Read xpub | ✓ | ✓ | ✓ |
| Show + verify address (single-sig) | ✓ (not taproot) | ✓ | ✓ |
| Show + verify address (multisig) | ✓ | ✓ (after registration) | ✓ |
| Register multisig | ✓ (uploads setup file) | ✓ | not needed (stateless) |
| Sign single-sig | ✓ | ✓ | ✓ (incl. taproot) |
| Sign multisig | ✓ | ✓ (after registration) | ✓ (multisig acks built in `hwi/trezor.rs`) |
| Unlock | on device | on device + Blockstream PIN server | on device (newer models); PIN matrix in Northvault (Model One) |

Device code compiles and the multisig key ordering is unit tested, but **none of it has been
fully validated against real devices yet**. Trezor Model One supports PIN-matrix entry
in Northvault, including a masked passphrase form when on-device entry is unavailable. Coldcard taproot
address display over USB isn't available in the `coldcard` crate.
Jade multisig uses descriptor registration, which needs recent Jade firmware. Build without
USB support with `cargo build --no-default-features` (air-gapped only).

Under Receive, each detected device has its own **Verify on …** button, even when
locked or showing a cached fingerprint from another passphrase wallet. Matching
fingerprints appear first. Buttons fill each row from left to right and wrap to
the next row only when needed. Discovery is not proof that the device owns this
account. Unlock/select the correct wallet when prompted. Verification succeeds
only when the address returned by the device matches the stored descriptor.
When no devices are detected, **Find devices** replaces the verification buttons.
The sidebar's **Hardware devices** control can also refresh discovery.

Click the receive address once to copy the full, unformatted address. Hovering
shows a copy cursor and a small copy icon at the field's top-right corner; a
checkmark confirms copying. **Next address** sits alongside the address with the
same height and shows only its icon when space is limited.
**Show QR code** opens the current address as a BIP21 QR in a translucent overlay
covering the entire app window, like the Trezor PIN matrix. Close it with Escape
or a click on the dimmed area outside the card. Receive and account-action cards use the full
available width, including wider windows; their contents expand with the cards.

The supplied shield SVG is retained in `macos/Northvault/Resources/NorthvaultLogo.svg`.
Its PNG and app icon are generated offline with `bash scripts/build-logo.sh`.
Every generated QR, including each animated signing frame, embeds this logo via
the vendored EFQRCode library. A bundled Arase encoder runs locally in JavaScriptCore;
no payload reaches a browser or server. High error correction, integer-size modules,
a white quiet zone, and an independent Vision decode check protect readability and
exact payload preservation. Generation failures show a message instead of a blank QR.
Frames are prepared off the main thread and released when the overlay closes.
Limits are 1,000 UTF-8 bytes per frame, 128 frames, and 64 MiB of rendered frames;
larger exports show an error directing the user to file export.

After `make build`, run `bash scripts/test-qr.sh` for synthetic address/BIP21,
Unicode, branded-image decode, display-size, and single/multipart PSBT round trips.
`bash scripts/test-panels.sh` also checks QR preparation/cancellation/error recovery.
Physical camera/device scanning and real overlay interaction remain acceptance checks.

For isolated UI checks, run `make build` and `bash scripts/build-receive-preview.sh`,
then open `macos/build/NorthvaultReceivePreview.app`. This fixture uses synthetic
sample data and disables USB actions. Check wide/narrow layouts, zero/one/three
device buttons, single-click copy with **Check copied address**, and **Next address**
updating the address and the next opened QR while clearing copy feedback. Check
**Show QR code**, the shield, blocked background interaction, and outside/Escape
dismissal; opening a QR must not derive another address.
**Account panel checks** opens the real sidebar and account actions using a
temporary synthetic wallet, starting at the full-workspace account setup. Check the
policy slider and corresponding key slots, action titles/cards, repeated account selection,
and returning to Transactions without a Back button. USB discovery and automatic
sync are disabled; only use synthetic files when exercising import/export.
**Test PIN overlay** exercises the real app-modal overlay without hardware. Check
mouse/keyboard positions, Delete last, Return/Unlock, outside-click/Escape cancellation,
and blocked wallet shortcuts. **Test PIN timeout** uses a three-second test deadline;
production requests retain the five-minute deadline. No entered positions are displayed
in the preview result or sent to any device.

Coldcard and Trezor library calls run serially on a persistent hardware thread.
Do not move Coldcard discovery or device calls onto Tokio's temporary blocking pool:
macOS HIDAPI retains the first caller's run loop for the lifetime of the process.
The supplied `crash.log` shows a native trap in that discovery path after an idle
period. The thread-lifetime fix has automated regression coverage; reconnecting and
using a physical wallet after an idle period still needs hardware verification.
These existing dependencies have not been independently reviewed. Bitcoin Core HWI is a possible separate-process replacement, but is
not installed or integrated by this fix.

### Trezor Model One PIN entry

Select the Trezor under **Add account → Keys → Device**. When the device requests
its current PIN, Northvault opens the **Unlock your Trezor** overlay. Read the scrambled
numbers on the device and click their corresponding positions in the blank 3×3 grid,
then click **Unlock**. The protocol uses numeric-keypad positions (7–8–9 at the top,
1–2–3 at the bottom); the app does not display those numbers as PIN digits.

Clicking outside the PIN box, Escape, closing the parent window, or a five-minute
timeout aborts the device request. Return or Unlock submits a nonempty entry.
Keyboard 1–9 selects matrix positions, never the device’s scrambled PIN digits. Incorrect PINs are not
retried automatically. PIN changes and recovery are not supported. Matrix positions are transient and never persisted; protocol TRACE/DEBUG
logging is compiled out because the upstream client logs outbound messages at TRACE.
Swift, UniFFI and protobuf may make transient memory copies; this is not a guarantee
of secure memory erasure. The same overlay handles PIN requests during address display
and signing, while keeping the existing USB session open.

After PIN entry, passphrase-enabled Trezors may ask which wallet to open. On devices
that advertise on-device passphrase entry, Northvault requests it there. Otherwise,
choose **Use standard wallet** explicitly, or enter an existing wallet's exact
passphrase twice in the right-panel form. Cancel never selects an empty passphrase.
The host form accepts up to 50 UTF-8 bytes without trimming or normalization.
The passphrase is sent only to the connected Trezor, never saved or logged, and the
fields are cleared after use/cancellation/timeout. As with PIN positions, transient
memory copies cannot be guaranteed erased. A typo selects a different wallet; verify
its fingerprint and receive addresses before using it. Never enter a recovery seed.

The app isn't sandboxed, because Jade needs direct serial-port access. It runs
with the hardened runtime and the camera and USB entitlements (`Northvault.entitlements`).

## Replacing the remaining sample data

Wallets, sync, fees, sending and labels are real. Only prices are still sample data:

1. **Prices / FX:** implement `PriceSource` in `core/src/chain/price.rs` with a reviewed
   feed and use it in `WalletService::open`. History needs daily closes, plus FX rates for EUR, GBP, CHF and JPY.
2. **Server:** Mainnet defaults to Blockstream's public Electrum server. A public server
   learns the user's addresses. Change the address in Settings to use your own
   Electrum, electrs or Fulcrum.

## Third-party dependencies and network services

Review these before adding to them:

- Rust: `bdk_wallet` (+ `rusqlite`), `bdk_electrum` / `electrum-client` (rustls), `async-hwi`
  (+ `coldcard`, `hidapi`, `tokio-serial`, `reqwest` with rustls / aws-lc for Jade's PIN
  server), `trezor-client` (+ `protobuf`, `rusb` with vendored libusb), `ur`, `tokio`, `serde`,
  `serde_json`, `base64`, `uniffi`, `thiserror`. Exact versions are in `core/Cargo.lock`.
- Network: the user's Electrum server; Blockstream's PIN server when a Jade is unlocked.

## Verification

Done so far, on a Mac with Command Line Tools only (no Xcode):

- `make test`: 37 Rust tests pass (see REVIEW.md for what they cover).
- Release builds for arm64 and x86_64, combined with `lipo`; Swift bindings generate.
- All Swift sources type-check against the generated bindings (macOS 14 target).
- The Swift app links against the Rust static library with the frameworks from `project.yml`.
- A Swift smoke test through the real FFI passes: create wallet, BIP84 address, export and
  re-import, labels persisted, async calls.

Not done yet:

- `xcodebuild -create-xcframework` and running the app (needs Xcode).
- Manual verification on signet or testnet4:
  1. Create a 2-of-3 in another descriptor wallet from a Coldcard, a Jade and a Trezor. Export the descriptor
     and import it here. The first 5 receive and change addresses must match.
  2. Build a PSBT here and open it in the other wallet. Outputs and fee must be identical.
  3. Sign on the Coldcard via SD card, the Jade via QR and the Trezor via USB, then broadcast.
     The other wallet shows the transaction.
  4. "Verify on device" shows the same address on each device.
  5. Export BIP329 labels here and import them into the other wallet.
- The live Regtest suite passes in the Colima/arm64 Docker environment:
  `docker compose run --build --rm tests` provides the dependencies in containers;
  alternatively, `make regtest-test` uses locally installed Bitcoin Core and electrs.
  Consecutive runs on the same disposable chain pass with isolated test-only keys.
  Offline Regtest integration tests run with `make test`. See [TESTING.md](TESTING.md)
  for the reusable air-gapped signer, coverage reports, and outstanding gaps.
- Account key QRs (`crypto-account`) and descriptor QRs (`crypto-output`) are tested against
  SeedSigner's published vectors and the BCR field layout, not yet against a physical SeedSigner,
  Keystone, Passport or Jade camera. Specter's legacy `p1of2 …` key QR and `crypto-hdkey` are not read.

## Security notes

- Private keys and signing never live in this app (Swift or Rust). Spending produces an unsigned
  PSBT for the hardware device, and every signed PSBT is checked against it before broadcast.
- No credentials, API keys or server secrets in source.
- Spending, address generation/verification, fee calculation and device code are
  **security-sensitive**. See [REVIEW.md](REVIEW.md).

## Encrypted descriptors on macOS and iOS

The new **File → Encrypted Wallets** section uses the shared Swift package in
`shared/`. **Account → Create Encrypted Backup** copies an existing descriptor
into its protection workflow, leaving the original local wallet untouched.
The storage-only macOS/iOS clients are defined in `apple/project.yml`.

The workflow validates a descriptor pair or multipath descriptor, accepts one
independent BIP-85 HEX output per authorized signer, encrypts a separate random
wallet key for each signer, and writes `<walletId>.walletenc`. A single signer
can recover the descriptor without other signers and without changing the
transaction-signing policy. Single-sig and multisig accounts remain separate
wallets even when they use the same signer secret.

**BIP-85 secrets are stored only in Keychain.** The import and unlock screens offer
an explicit opt-in to synchronize those secrets via iCloud Keychain. Wallet DEK
synchronization is a separate choice. No BIP-85 secrets, names, xpubs or plaintext
descriptors are stored in iCloud Drive metadata. Public envelope fingerprints are
only hints. Direct hardware BIP-85 extraction is not implemented.

### Local builds and tests

```sh
make storage-test   # CryptoKit, descriptor, recovery, file and Keychain-contract checks
make test           # existing Rust wallet tests
make build          # existing macOS app plus shared storage libraries; CLT supported
```

The macOS storage suite also checks native rendered lock/recovery screens using
Tesseract 5 with English data. Install that test tool or set `TESSERACT` to its
executable path; it is not linked into the app. See `TESTING.md` for snapshot
artifacts and the remaining UI/OS acceptance gaps.

`make storage-test` uses synthetic fixtures, real CryptoKit, the real Rust
Miniscript bridge, real temporary files, an in-memory Keychain and a test
coordinator. It does not access your wallet, iCloud or Keychain. Full Xcode is
needed for ordinary `swift test`; this machine currently has only Command Line
Tools. With full Xcode, first build the host descriptor library, then run:

```sh
cd descriptor-core
cargo build --locked --target aarch64-apple-darwin
cd ../shared
swift test -Xlinker -L../descriptor-core/target/aarch64-apple-darwin/debug -Xlinker -lnorthvault_descriptor
```

Use `x86_64-apple-darwin` instead on an Intel Mac. Tests import their fixture
resource through SwiftPM. The command sandbox here blocks NSFileCoordinator
operations, so the local checks inject a coordinator; production always uses
NSFileCoordinator and reports errors instead of silently falling back.

### Signed Apple clients and provisioning

1. Install full Xcode, select it with `xcode-select`, install the iOS SDK/simulator,
   and install XcodeGen. The local CLT build cannot build or run iOS targets.
2. Copy `apple/Signing.local.xcconfig.example` to `apple/Signing.local.xcconfig`.
   Set your development team, unique bundle prefix, shared iCloud container and
   common Keychain access group. Keep credentials/certificates out of the repo.
3. Register both app IDs with the same Apple Developer team and compatible
   AppIdentifierPrefix. Enable **iCloud Documents** and **Keychain Sharing** on
   both IDs; associate both with the same iCloud container and access group.
   Ensure provisioning profiles contain these exact entitlements.
4. Run `make storage-apple`. This builds descriptor libraries for macOS, iOS arm64
   and both simulator architectures, packages an XCFramework and generates
   `apple/NorthvaultStorage.xcodeproj`.
5. Open that project. Build `NorthvaultStorageMac` and `NorthvaultStorageIOS`.
   The existing full macOS application can be generated with `make project`; it
   uses the same storage container/group via `apple/StorageMac.entitlements`.
6. On physical devices, sign in to the same Apple Account and enable iCloud Drive
   and iCloud Passwords & Keychain. Test creating a synthetic wallet on macOS,
   discovering it on iPhone, and unlocking via the opt-in DEK/secret sync.

The ad-hoc `make build` bundle intentionally does not include provisioned cloud
entitlements. It falls back to local encrypted storage. Access-group and Keychain
errors are surfaced; an ad-hoc signature is not proof of working Keychain sync.
Use the signed storage-only targets for isolated descriptor-manager testing.

For example unsigned build validation after `make storage-apple`:

```sh
xcodebuild -project apple/NorthvaultStorage.xcodeproj -scheme NorthvaultStorageMac \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/NorthvaultStorage.xcodeproj -scheme NorthvaultStorageIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

### Physical-device acceptance checklist

- Import a synthetic 2-of-3 descriptor and protect it with three independent HEX
  values. Recover from a fresh key cache using each value separately.
- Protect a separate single-sig account with signer A's same secret. Delete DEK
  caches and recover either account using its own file, independently.
- Verify macOS → iOS and iOS → macOS Drive discovery and Keychain propagation;
  exercise DEK-only sync, secret sync, opt-out, deletion, and access-group errors.
- Disable networking: reopen a previously downloaded encrypted offline snapshot.
  Edit on two devices, reconnect, and verify conflicts are preserved, not silently
  overwritten. Reimport the same UUID and equivalent descriptors with a new UUID.
- Reset a test signer and restore its original seed/passphrase on-device; export
  the same BIP-85 HEX output and recover. Do not enter that seed in Northvault.
- Test Face ID/Touch ID/device-passcode gating and background locking.
- Export an encrypted file to a shared iCloud folder under another Apple Account.
  Confirm it stays locked until a valid separately delivered secret is supplied.

Encrypted exports are portable without iCloud. Shared folders are explicitly
selected using the document picker and security-scoped bookmarks. Private
reconciliation groups equivalent unlocked imports, but preserves their encrypted
files and recovery slots; locked/offline duplicates can temporarily coexist.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the exact v1 encoding and data flow and
[SECURITY.md](SECURITY.md) for trust assumptions, retained legacy files, rotation,
secret synchronization, backup requirements and testing limitations.

For a local storage-only macOS build without Xcode, run `make storage-build-local`.
It produces `macos/build/NorthvaultStorage.app`, using the same SwiftUI entry point
as the iOS target and statically linked libraries. This build has no cloud
entitlements and does not initialize the legacy blockchain backend.

### Automatic encrypted-wallet discovery

Northvault starts discovery at launch, without an import dialog, and refreshes
while running every 15 seconds. It reads `.walletenc` files directly from these
fixed locations (paths are inside the app sandbox on iOS and sandboxed macOS):

- Application Support/NorthvaultEncrypted
- Application Support/NorthvaultEncrypted/Inbox
- Application Support/NorthvaultEncrypted/Offline
- Documents/Northvault/Wallets
- The configured iCloud container's Documents/Wallets directory

Previously authorized shared folders are also restored and scanned. No Downloads
or arbitrary home folders are scanned. Missing local discovery folders are normal;
they need not be created until used. The wallet screen shows the actual paths.
Discovery does not copy files or rewrite descriptors. UUID and authenticated
identity grouping prevent repeat scans from creating duplicate wallet entries.
Cached Keychain access unlocks discovered files automatically unless authentication
or an explicit local lock is required. Other wallets appear locked for recovery.

The full macOS app starts scanning in the background independently of opening
Settings. Encrypted wallets, recovery, import and account backup creation are
accessible exclusively through **Settings → Encrypted wallets**. Settings uses
clickable Display, Connection, Encrypted wallets, Privacy and Data tabs with the
same card surface as Net Worth. Manual descriptor/file import remains in the
wallet tab's **Settings** menu. Discovered descriptors remain in encrypted storage;
discovery does not create plaintext copies in the legacy transaction database.
