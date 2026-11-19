# Encrypted descriptor storage

The existing macOS wallet remains intact. `File > Encrypted Wallets` opens the
shared storage UI; `Account > Create Encrypted Backup` copies a descriptor into
the new workflow. Existing plaintext `wallets.json`, SQLite, labels and imported
files remain local and are **not migrated or uploaded**. No legacy registry or
transaction database is used by the storage module. iOS presents only the shared
descriptor manager, without transaction signing, balances or a network backend.

## Modules

- `descriptor-core`: pinned Rust Miniscript 12.3.8 validation behind two C ABI
  functions (`nv_descriptor_validate`, `nv_descriptor_free`). It accepts public
  descriptors, validates supplied checksums and script sanity, and reports
  canonical receive/change branches, original inputs, network, policy and origins.
  Supported policies: pkh, wpkh, key-only tr, sh-wpkh, wsh/sh-wsh/sh multi and
  sortedmulti. Unsupported scripts are rejected, not rewritten. Origins and
  unhardened wildcard xpubs are required. Testnet/signet/regtest all use test xpubs;
  the caller explicitly chooses the network. No blockchain or USB dependencies.
  The full macOS app links this crate through its existing Rust core to share one
  secp256k1 implementation. Storage-only targets link the standalone bridge.
- `shared/WalletModels`: wallet UUIDs, names, origins, descriptors and validation.
- `shared/WalletCrypto`: CryptoKit envelope encryption and slot management.
- `shared/WalletStorage`: async actor repositories, Security.framework Keychain,
  coordinated encrypted files, offline snapshots and iCloud discovery.
- `shared/WalletUI`: shared SwiftUI import/protect/unlock/details/recovery controls.
  macOS hosts these in the existing right panel. iOS uses a scrollable native
  navigation view. File pickers/exporters use native platform document interfaces.

## Startup discovery

The macOS AppState owns one shared VaultModel and starts it at application launch,
independently of opening the encrypted-wallet panel. The standalone clients start
it with their root wallet view. WalletLocations defines fixed Application Support,
Inbox, Offline and Documents/Northvault/Wallets locations. The configured iCloud
store and restored security-scoped shared folders supplement those locations.
Scans repeat every 15 seconds; an unavailable primary store does not prevent local
discovery. Files are read in place and authenticated before displaying payloads;
no import wizard, plaintext registry or implicit legacy database import is used.
The list groups repeated UUIDs and authenticated equivalent descriptors, preserving
all original ciphertext and conflict copies. Manual import lives under Settings.

## Data flow

1. Validate a descriptor pair or two-branch multipath descriptor using Miniscript.
2. Generate a random wallet UUID and random 32-byte DEK.
3. For each supplied 32-byte BIP-85 secret, generate a slot UUID and random salt,
   derive a KEK with HKDF-SHA256, and AES-GCM-wrap the same DEK independently.
4. Encrypt the entire payload, including all descriptor data and its name. Verify
   every supplied slot can unwrap and authenticate it before committing the file.
5. Save BIP-85 material only to Keychain. Secret sync and DEK sync are independent
   opt-in controls; default secret storage and default cached DEK storage are local.
6. Write `<walletId>.walletenc` under the app's iCloud Documents/Wallets directory
   when configured, or local Application Support/NorthvaultEncrypted otherwise.
7. Another client discovers/downloads ciphertext, tries its cached DEK, then saved
   signer secrets, then manual HEX input. Only authenticated data is displayed.
8. Keep authenticated ciphertext snapshots under local `Offline/` for offline
   recovery and known-revision rollback detection. No plaintext local index exists.

Manual HEX is 64 ASCII hexadecimal characters, case insensitive, permitting only
surrounding whitespace. It is decoded once to 32 bytes. The app does not implement
BIP-85 derivation or request seed words/xprvs. The default path is
`m/83696968'/128169'/32'/0'`; the final hardened index is configurable per slot.
Restoring the original root (including the original BIP-39 passphrase) and deriving
the same BIP-85 output reproduces the recovery input.

## Version 1 envelope and associated data

The portable JSON fields are:

- `formatVersion` = 1, random `walletId`, positive integer `revision`, random
  `revisionId`, optional `parentRevisionId`, random `keyGeneration`.
- `algorithm` = `AES-256-GCM`, `payload`: Base64 sealed box.
- `keySlots`: array of `id`, uppercase 8-character `fingerprint`, `cosignerIndex`,
  `bip85Index`, `bip85Path`, `kdf` = `HKDF-SHA256`, `hkdfSalt`, `wrappedDEK`.

Every sealed box encodes **12-byte nonce || ciphertext || 16-byte tag**. The salt
is 32 bytes; a wrapped 32-byte DEK is exactly 60 bytes. Nonces and keys use
SecRandomCopyBytes; every seal gets a fresh random nonce. Files are capped at
4 MiB, descriptor inputs at 128 KiB each, and slot count at 20. Future versions,
unknown algorithms, malformed lengths and duplicate slot UUIDs are rejected.

AAD uses fields framed as UInt64 big-endian byte length followed by bytes.
Strings are UTF-8. UUIDs are lowercase standard UUID strings; numbers are decimal
without padding. JSON whitespace/key ordering is not part of authentication.

Base fields: `northvault.walletenc`, format version, wallet UUID, key-generation
UUID, algorithm. Slot fields: slot UUID, fingerprint, cosigner index, path, BIP-85
index, KDF name, then raw salt bytes.

- HKDF info: framed base fields + `kek` + slot UUID.
- Slot AAD: framed base fields + `slot` + slot fields.
- Payload AAD: framed base fields + `payload`, revision, revision UUID, parent UUID
  (empty when absent), then one framed slot-fields-plus-wrappedDEK blob per slot,
  in array order. This authenticates the complete slot manifest.

Slot wraps bind to key generation, not payload revision. This permits ordinary
metadata/slot changes without asking every retained signer for its secret again.
Rotation generates a new DEK and generation, rewraps retained slots, and requires
each retained secret. Removing a slot alone is explicitly not revocation.

## Identity, duplicate imports and conflicts

Wallet UUIDs are random, not public hashes of descriptors. After authenticated
unlock, the app compares canonical descriptor pairs and explicit network. It
normalizes sortedmulti key order but preserves multi order, origins and branch
semantics. Single-sig and multisig using the same signer remain different wallets.

Exact UUID imports reuse the file. Equivalent independent imports are grouped
into one logical list entry after unlocking; the smallest UUID is the display
representative. Related files remain selectable and independently recoverable.
No slots are copied across different DEKs, and no file is automatically deleted.
Offline/locked duplicates may temporarily be visible. This is eventual private
reconciliation, not a global uniqueness transaction.

A coordinated update compares the expected ciphertext digest and parent revision
before replacing the current file. Divergent edits produce conflict copies; the
last valid ciphertext is retained as a previous revision. iCloud NSFileVersion
conflicts are copied for review and are not automatically marked resolved.
Corrupt or unauthenticated replacements are rejected. Previously authenticated
local snapshots help detect older cloud revisions. A new installation cannot
prove that a valid older file is the latest one.

## Keychain and cloud separation

BIP-85 records have opaque UUID identifiers. Fingerprints are hints only; matching
an item does not authorize access. Candidate secrets must pass AEAD verification.
DEKs are indexed by wallet UUID and key generation. Local items use
WhenUnlockedThisDeviceOnly, synchronized items use WhenUnlocked. macOS uses the
Data Protection Keychain and the same configured access group as iOS.

NSMetadataQuery discovers cloud documents; download requests are explicit because
metadata can arrive before contents. NSFileCoordinator guards production I/O.
A periodic refresh also reconciles local/shared-folder changes while the view is
alive. Apple Account identity changes lock the UI and reopen the appropriate
container. Shared folder bookmarks are local security-scoped references; no
secret is put in a shared folder. Encrypted export supports different Apple IDs,
but recipients need an authorized BIP-85 secret obtained separately.
