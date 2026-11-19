# Security and recovery limitations

This is an unreviewed local implementation, not a security-audited wallet product.
Use synthetic descriptors and secrets until independent review and signed-device
testing are complete. Existing Bitcoin transaction signing is outside this new
storage module; encrypted descriptor access never authorizes transaction signing.

## Trust boundaries

- Descriptors, xpubs, wallet names and origins are encrypted in iCloud Drive.
  Public envelope metadata exposes UUIDs, revisions, recovery fingerprints,
  derivation paths, slot counts and ciphertext size. Fingerprints can collide and
  never authenticate a signer.
- AES-256-GCM and HKDF-SHA256 come from CryptoKit. Public identifiers and xpubs are
  never used as encryption secrets. No fallback to plaintext is implemented.
- The app never receives a seed phrase, BIP-32 private key or signing key. It does
  receive a BIP-85 HEX output with significant recovery power. The app cannot
  verify that a user-supplied output actually came from the claimed hardware seed.
  Verify the device, passphrase, application, length and index yourself.
- No direct BIP-85 device export is implemented. Device/firmware/transport support
  must be verified separately for COLDCARD, Trezor, Jade or other devices.
- Compromise of a saved BIP-85 secret permits recovery of every available file
  authorized by that secret. Per-wallet DEKs/KEKs prevent dependence on another
  file, but do not limit the recovery scope of that shared secret.
- Secret synchronization is an explicit opt-in to **iCloud Keychain**, never Drive.
  It extends that recovery scope to your trusted Apple Account devices. Different
  Apple Accounts do not automatically share Keychain items.
- Optional device-authentication UI gating is not Secure Enclave protection of a
  synchronizable DEK. It is not protection against a compromised app process.

## Backup and recovery

Every wallet file carries its own payload and independent encrypted DEK slots.
Recovering a 2-of-3 descriptor needs any one authorized slot, not two signing
seeds. The 2-of-3 transaction policy remains unchanged. A single-sig account and a
multisig account protected by the same BIP-85 output can each be recovered using
only their own file and that output.

Keep offline `.walletenc` backups plus the original hardware seed/passphrase
backups outside this app. A multisig seed backup alone does not guarantee recovery
of the descriptor or other cosigners' public data. Test each slot on a fresh
installation with no DEK cache before relying on it. Restoring the same seed with
a different passphrase or using a different BIP-85 index produces a different
secret and must fail cleanly.

Deleting a slot does not revoke a DEK already learned by its holder. Full rotation
creates a fresh DEK and requires every retained signer's recovery secret. The UI
refuses to silently drop a retained signer when that secret is unavailable.
Previously exported files and previous-revision backups remain decryptable with
their previous DEKs. Rotation does not erase remote copies or historical access.

Deleting a synchronized Keychain item propagates to other devices. Moving a
secret from synchronized to local saves the local copy before deleting the
synchronized record. Clearing local wallet access disables automatic unlocking
on that device and removes its local DEK; it does not delete shared signer secrets
needed by other accounts or pretend to revoke cloud copies.

## Local data, memory and operating system

The older macOS wallet still stores plaintext descriptors in its existing local
registry/SQLite databases. Creating an encrypted backup does not erase those
files or imported plaintext sources. They are never uploaded by this module.
The legacy blockchain backend may still query the user's configured server when
the existing wallet runs. The separate descriptor-manager client does not.

New wallet payloads remain in memory while unlocked, and secrets exist briefly
while importing, deriving or calling Keychain. Locking/backgrounding clears view
references and secret fields. Swift Data/String and system frameworks may retain
copies; guaranteed zeroization is not claimed. Descriptors can be selected/copied
after reveal; copied clipboard contents are outside the encrypted file boundary.
No secrets, plaintext descriptors, keys or payloads are intentionally logged.

iCloud is asynchronous and does not provide a global compare-and-swap. File
coordination, parent revisions and conflict preservation reduce accidental data
loss, but offline branches may temporarily coexist. Known local snapshots expose
rollback; fresh devices cannot establish the latest historical revision without
another trusted source. No automatic deletion or destructive duplicate merging
is performed.

## Validation status

Run `make storage-test` for actual CryptoKit/Miniscript tests with synthetic keys,
real disk writes, an injected test file coordinator and an in-memory Keychain.
The command sandbox prevents NSFileCoordinator from entering its operation block
(NSCocoaErrorDomain 512); production never falls back to uncoordinated writes.
Real Security.framework behavior, entitlements, NSMetadataQuery delivery,
NSFileVersion conflict handling, Face ID/Touch ID, security-scoped sharing and
cross-device synchronization require signed physical-device tests.

The local ad-hoc build is suitable for compilation/UI inspection. It does not
prove that Apple will permit shared/synchronizable Keychain or iCloud access.
