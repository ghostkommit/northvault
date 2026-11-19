import Foundation
import WalletModels
import WalletCrypto
import WalletStorage

// These workflows use real CryptoKit, the Rust descriptor ABI and temporary disk
// storage. Only Keychain and file coordination are substituted OS boundaries.
private func expectVaultError(_ expected: VaultError, _ message: String, _ action: () async throws -> Void) async throws {
    do { try await action() }
    catch let error as VaultError {
        try require(error == expected, message + ": wrong error")
        try require(!(error.errorDescription ?? "").isEmpty, message + ": missing user-facing error")
        return
    }
    throw CheckFailure(message: message + ": unexpectedly succeeded")
}

private struct FailedCoordinator: FileCoordinating {
    func coordinate<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        throw VaultError.unavailable("Synthetic coordination failure")
    }
}

private struct RecoveryFixture {
    let root: URL
    let descriptors: ValidatedDescriptors
    let auths: [SignerAuthorization]
    var payload: WalletPayload { WalletPayload(name: "Regtest recovery fixture", descriptors: descriptors) }

    func store(_ name: String) throws -> EncryptedFileStore {
        try EncryptedFileStore(directory: root.appendingPathComponent(name), coordinator: TestFileCoordinator())
    }
    func repository(_ name: String, keychain: MemoryKeychain) throws -> WalletRepository {
        WalletRepository(files: try store(name), keychain: keychain)
    }
}

func runRecoveryChecks(fixtures: [String: String]) async throws -> Int {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("northvault-recovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptors = try DescriptorValidator().validate(receive: fixtures["multi"]!, change: nil, network: .regtest)
    let auths = try descriptors.cosigners.enumerated().map { index, signer in
        SignerAuthorization(fingerprint: signer.fingerprint, index: UInt32(index),
            secret: try BIP85Secret(data: Data(repeating: UInt8(index + 11), count: 32)), cosignerIndex: index)
    }
    let fixture = RecoveryFixture(root: root, descriptors: descriptors, auths: auths)
    try checkEnvelopeBoundaries(fixture)
    try checkAuthenticatedMetadata(fixture)
    try await checkSecretMoves(fixture)
    try await checkCacheMoves(fixture)
    try await checkRecoveryRotation(fixture)
    try await checkConflictingWrites(fixture)
    try await checkOfflineRecovery(fixture)
    try await checkRepositoryImportAndFailures(fixture)
    return 8
}

private func checkEnvelopeBoundaries(_ f: RecoveryFixture) throws {
    let (valid, key) = try EnvelopeCrypto.create(f.payload, authorizations: f.auths)
    try require(valid.id == valid.walletId, "envelope identity for displayed records")
    let mutations: [(String, (inout WalletEnvelope) -> Void)] = [
        ("unsupported version", { $0.formatVersion = 2 }),
        ("unknown cipher", { $0.algorithm = "unknown" }),
        ("zero revision", { $0.revision = 0 }),
        ("short sealed payload", { $0.payload = Data(repeating: 0, count: 27) }),
        ("no recovery slots", { $0.keySlots = [] }),
        ("too many slots", { $0.keySlots = Array(repeating: $0.keySlots[0], count: 21) }),
        ("duplicate slot identity", { $0.keySlots[1].id = $0.keySlots[0].id }),
        ("short salt", { $0.keySlots[0].hkdfSalt.removeLast() }),
        ("short wrapped key", { $0.keySlots[0].wrappedDEK.removeLast() }),
        ("unknown KDF", { $0.keySlots[0].kdf = "unknown" }),
        ("out-of-range BIP85 index", { $0.keySlots[0].bip85Index = 0x80000000 }),
        ("incorrect BIP85 path", { $0.keySlots[0].bip85Path = "m/0'" }),
        ("negative signer index", { $0.keySlots[0].cosignerIndex = -1 }),
        ("oversized signer index", { $0.keySlots[0].cosignerIndex = 20 }),
        ("short fingerprint", { $0.keySlots[0].fingerprint = "1234" }),
        ("nonhex fingerprint", { $0.keySlots[0].fingerprint = "GGGGGGGG" })
    ]
    for (name, mutate) in mutations {
        var envelope = valid; mutate(&envelope)
        let bytes = try JSONEncoder().encode(envelope)
        try rejects(name + " must fail parsing") { _ = try WalletEnvelope.read(bytes) }
        try rejects(name + " must fail decryption") { _ = try EnvelopeCrypto.decrypt(envelope, dek: key) }
    }
    for bytes in [Data(), Data("{}".utf8), Data(repeating: 0, count: 4 * 1024 * 1024 + 1)] {
        try rejects("bounded malformed envelope") { _ = try WalletEnvelope.read(bytes) }
    }
    for bytes in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 33)] {
        try rejects("secret length") { _ = try BIP85Secret(data: bytes) }
        try rejects("DEK length") { _ = try EnvelopeCrypto.decrypt(valid, dek: bytes) }
    }
    for hex in [String(repeating: "g", count: 64), String(repeating: "é", count: 32), String(repeating: "0 ", count: 32)] {
        try rejects("malformed hexadecimal secret") { _ = try BIP85Secret(hex: hex) }
    }
    let whitespace = try BIP85Secret(hex: " \n" + String(repeating: "a0", count: 32) + "\t")
    try require(whitespace.keychainData() == Data(repeating: 0xa0, count: 32), "only surrounding HEX whitespace is accepted")
    for (receive, change) in [(f.descriptors.receive + "\0", nil), (f.descriptors.receive, "\0"), (String(repeating: "x", count: 131073), nil), (f.descriptors.receive, String(repeating: "x", count: 131073))] {
        try rejects("Swift descriptor size and encoding boundary") {
            _ = try DescriptorValidator().validate(receive: receive, change: change, network: .regtest)
        }
    }
    let highest = SignerAuthorization(fingerprint: f.auths[0].fingerprint, index: 0x7fffffff, secret: f.auths[0].secret, cosignerIndex: 0)
    let (boundary, boundaryKey) = try EnvelopeCrypto.create(f.payload, authorizations: [highest])
    try require(try EnvelopeCrypto.unwrap(boundary, secret: highest.secret, slotId: boundary.keySlots[0].id) == boundaryKey, "highest allowed BIP85 index recovers")
    try rejects("no authorized recovery signer") { _ = try EnvelopeCrypto.create(f.payload, authorizations: []) }
    try rejects("duplicate authorization") { _ = try EnvelopeCrypto.create(f.payload, authorizations: [f.auths[0], f.auths[0]]) }
    for auth in [
        SignerAuthorization(fingerprint: f.auths[0].fingerprint, index: 0x80000000, secret: f.auths[0].secret, cosignerIndex: 0),
        SignerAuthorization(fingerprint: "00000000", secret: f.auths[0].secret, cosignerIndex: 0),
        SignerAuthorization(fingerprint: f.auths[0].fingerprint, secret: f.auths[0].secret, cosignerIndex: 3)
    ] { try rejects("invalid signer authorization") { _ = try EnvelopeCrypto.create(f.payload, authorizations: [auth]) } }
}

private func checkAuthenticatedMetadata(_ f: RecoveryFixture) throws {
    let payload = f.payload
    let (valid, key) = try EnvelopeCrypto.create(payload, authorizations: f.auths)
    let mutations: [(inout WalletEnvelope) -> Void] = [
        { $0.walletId = UUID() }, { $0.keyGeneration = UUID() }, { $0.revision += 1 },
        { $0.revisionId = UUID() }, { $0.parentRevisionId = UUID() },
        { $0.keySlots.swapAt(0, 1) }, { $0.keySlots.removeLast() },
        { $0.keySlots[0].id = UUID() }, { $0.keySlots[0].fingerprint = "DEADBEEF" },
        { $0.keySlots[0].cosignerIndex = 2 },
        { $0.keySlots[0].bip85Index = 5; $0.keySlots[0].bip85Path = EnvelopeCrypto.path(5) },
        { $0.keySlots[0].hkdfSalt[0] ^= 1 }, { $0.keySlots[0].wrappedDEK[0] ^= 1 },
        { $0.payload[0] ^= 1 }, { $0.payload[$0.payload.count - 1] ^= 1 }
    ]
    for mutate in mutations {
        var envelope = valid; mutate(&envelope)
        try envelope.checked() // Structurally valid is not authenticated.
        try rejects("authenticated envelope metadata substitution") { _ = try EnvelopeCrypto.decrypt(envelope, dek: key) }
    }
    var emptyName = payload; emptyName.name = " \n"
    let (invalidPayload, invalidKey) = try EnvelopeCrypto.create(emptyName, authorizations: f.auths)
    try rejects("authenticated but invalid payload") { _ = try EnvelopeCrypto.decrypt(invalidPayload, dek: invalidKey) }
    try rejects("unknown recovery slot") { _ = try EnvelopeCrypto.unwrap(valid, secret: f.auths[0].secret, slotId: UUID()) }
    try require(try EnvelopeCrypto.decrypt(valid, dek: key) == payload, "failed tampering leaves original decryptable")
}

private func checkSecretMoves(_ f: RecoveryFixture) async throws {
    let memory = MemoryKeychain()
    let secrets = SignerSecretStore(keychain: memory)
    let id = try await secrets.save(f.auths[0], mode: .synchronized)
    try require(try await secrets.save(f.auths[0], mode: .synchronized) == id, "identical secret is idempotent")
    let collision = SignerAuthorization(fingerprint: f.auths[0].fingerprint, index: f.auths[0].index, secret: f.auths[1].secret, cosignerIndex: 0)
    let other = try await secrets.save(collision, mode: .synchronized)
    try require(other != id, "matching fingerprint must not replace a different secret")
    let summaries = try await secrets.summaries()
    try require(summaries.count == 2 && summaries.allSatisfy { $0.mode == .synchronized }, "secret summaries reflect both recoveries")
    await memory.failSave(in: .local)
    try await expectVaultError(.keychain(-34018), "destination save failure") { try await secrets.move(id: id, from: .synchronized, to: .local) }
    try require(try await memory.load(id: "secret.\(id)", mode: .synchronized) != nil, "failed move preserves source")
    try require(try await memory.load(id: "secret.\(id)", mode: .local) == nil, "failed move does not create destination")
    await memory.failSave(in: nil)
    await memory.failDelete(in: .synchronized)
    try await expectVaultError(.keychain(-34018), "source deletion failure") { try await secrets.move(id: id, from: .synchronized, to: .local) }
    try require(try await memory.load(id: "secret.\(id)", mode: .local) != nil, "source deletion failure retains saved destination")
    try require(try await memory.load(id: "secret.\(id)", mode: .synchronized) != nil, "source deletion failure remains recoverable")
    await memory.failDelete(in: nil)
    try await secrets.move(id: id, from: .synchronized, to: .local)
    try await secrets.move(id: id, from: .local, to: .local)
    try require(try await memory.load(id: "secret.\(id)", mode: .synchronized) == nil, "successful move removes source only after saving")
    try await secrets.delete(other, mode: .synchronized)
    try require(try await secrets.summaries().count == 1, "deleting one secret preserves the other")
    try await expectVaultError(.missingKey, "move missing secret") { try await secrets.move(id: UUID(), from: .local, to: .synchronized) }
    let manual = ManualSignerSecretProvider { fingerprint, index in
        try require(fingerprint == "DEADBEEF" && index == 7, "manual recovery request context")
        return String(repeating: "0a", count: 32)
    }
    try require(try await manual.secret(fingerprintHint: "DEADBEEF", index: 7).keychainData() == Data(repeating: 10, count: 32), "manual recovery returns exact bytes")
    let cancelled = ManualSignerSecretProvider { _, _ in throw VaultError.unavailable("Cancelled") }
    try await expectVaultError(.unavailable("Cancelled"), "manual recovery cancellation") { _ = try await cancelled.secret(fingerprintHint: "DEADBEEF", index: 7) }
}

private func checkCacheMoves(_ f: RecoveryFixture) async throws {
    let memory = MemoryKeychain()
    let repository = try f.repository("cache", keychain: memory)
    let wallet = try await repository.create(name: "Regtest cache", descriptors: f.descriptors, authorizations: [f.auths[0]], secretMode: .local, cacheMode: .local)
    let envelope = wallet.stored.envelope
    try require(try await repository.hasCachedDEK(envelope), "new cached wallet is discoverable")
    await memory.failSave(in: .synchronized)
    try await expectVaultError(.keychain(-34018), "DEK destination failure") { try await repository.moveCache(wallet, from: .local, to: .synchronized) }
    try require(try await repository.unlock(wallet.stored).dek == wallet.dek, "DEK remains usable after failed move")
    await memory.failSave(in: nil)
    await memory.failDelete(in: .local)
    try await expectVaultError(.keychain(-34018), "DEK source deletion failure") { try await repository.moveCache(wallet, from: .local, to: .synchronized) }
    try require(try await memory.load(id: WalletRepository.keyID(envelope), mode: .synchronized) == wallet.dek, "DEK destination committed before deletion")
    await memory.failDelete(in: nil)
    try await repository.moveCache(wallet, from: .local, to: .synchronized)
    try await repository.moveCache(wallet, from: .synchronized, to: .synchronized)
    try await repository.clearCache(envelope, mode: .synchronized)
    try require(try await !repository.hasCachedDEK(envelope), "clearing DEK removes cached indicator")
    try require(try await repository.unlock(wallet.stored).dek == wallet.dek, "DEK removal preserves signer recovery")
    try await memory.save(Data(repeating: 0, count: 32), id: WalletRepository.keyID(envelope), mode: .local)
    try require(try await repository.unlock(wallet.stored).dek == wallet.dek, "invalid cached DEK falls back to authenticated signer")
    try await expectVaultError(.authentication, "wrong manual secret must not fall back to cache") { _ = try await repository.unlock(wallet.stored, manual: f.auths[1].secret) }
}

private func checkRecoveryRotation(_ f: RecoveryFixture) async throws {
    let memory = MemoryKeychain()
    let repository = try f.repository("rotation", keychain: memory)
    let original = try await repository.create(name: "Regtest rotation", descriptors: f.descriptors, authorizations: [f.auths[0]], secretMode: .local, cacheMode: nil)
    let added = try await repository.changeSlots(original, adding: [f.auths[1]], removing: [], secretMode: .synchronized)
    try require(added.stored.envelope.revision == 2 && added.dek == original.dek, "adding a slot preserves DEK and increments revision")
    try require(try await repository.unlock(added.stored, manual: f.auths[1].secret).dek == original.dek, "added signer recovers")
    let removed = try await repository.changeSlots(added, adding: [], removing: [added.stored.envelope.keySlots[0].id], secretMode: .local)
    try await expectVaultError(.authentication, "removed slot cannot unwrap current file") { _ = try await repository.unlock(removed.stored, manual: f.auths[0].secret) }
    try require(try EnvelopeCrypto.decrypt(removed.stored.envelope, dek: original.dek).descriptors == f.descriptors, "slot removal does not revoke previously known DEK")
    try await expectVaultError(.invalid("Keep at least one recovery signer"), "rotation cannot drop all signers") { _ = try await repository.rotate(removed, retaining: [], supplied: []) }
    try await expectVaultError(.invalid("Retained signer has no existing slot; add it before rotating"), "rotation cannot invent a retained slot") { _ = try await repository.rotate(removed, retaining: [2], supplied: []) }
    let emptyKeychain = MemoryKeychain()
    let fresh = await WalletRepository(files: repository.files, keychain: emptyKeychain)
    try await expectVaultError(.invalid("Supply the BIP-85 secret for retained signer 2; no signer will be silently removed."), "rotation needs retained recovery secret") { _ = try await fresh.rotate(removed, retaining: [1], supplied: []) }
    let rotated = try await fresh.rotate(removed, retaining: [1], supplied: [f.auths[1]])
    try require(rotated.dek != original.dek && rotated.stored.envelope.keyGeneration != original.stored.envelope.keyGeneration, "rotation changes key and generation")
    try require(rotated.stored.envelope.revision == removed.stored.envelope.revision + 1, "rotation advances revision")
    try rejects("old DEK cannot decrypt rotated file") { _ = try EnvelopeCrypto.decrypt(rotated.stored.envelope, dek: original.dek) }
    try require(try await fresh.unlock(rotated.stored, manual: f.auths[1].secret).dek == rotated.dek, "fresh machine recovers rotated file")
    try require(try await fresh.unlock(original.stored, manual: f.auths[0].secret).dek == original.dek, "historical backup still recovers independently")
    // Cached retained secrets can also rotate without another manual entry.
    _ = try await repository.rotate(rotated, retaining: [1], supplied: [])
}

private func checkConflictingWrites(_ f: RecoveryFixture) async throws {
    let files = try f.store("conflicts")
    let (envelope, key) = try EnvelopeCrypto.create(f.payload, authorizations: f.auths)
    let original = try await files.save(envelope, dek: key)
    let next = try EnvelopeCrypto.editSlots(envelope, dek: key)
    let committed = try await files.save(next, expected: original, dek: key)
    let stale = try EnvelopeCrypto.editSlots(envelope, dek: key)
    for _ in 0..<2 {
        try await expectVaultError(.conflict, "stale writer") { _ = try await files.save(stale, expected: original, dek: key) }
    }
    let copies = try await files.list()
    try require(copies.filter { $0.lastPathComponent.contains(".conflict-") }.count == 1, "same conflicting content preserved once")
    try require(copies.filter { $0.lastPathComponent.contains(".previous-") }.count == 1, "previous valid revision preserved")
    try require(try await files.read(committed.url).digest == committed.digest, "stale writes do not replace current content")
    let (unrelated, unrelatedKey) = try EnvelopeCrypto.create(f.payload, authorizations: f.auths)
    try await expectVaultError(.invalid("Wallet identity changed"), "cross-wallet overwrite") { _ = try await files.save(unrelated, expected: committed, dek: unrelatedKey) }
    // Deleting this test-owned file simulates an external deletion between read/write.
    try FileManager.default.removeItem(at: committed.url)
    let third = try EnvelopeCrypto.editSlots(next, dek: key)
    try await expectVaultError(.conflict, "missing expected revision") { _ = try await files.save(third, expected: committed, dek: key) }
    try require(!FileManager.default.fileExists(atPath: committed.url.path), "stale writer must not recreate a removed file")
    let oversized = f.root.appendingPathComponent("oversized.walletenc")
    try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: oversized)
    try await expectVaultError(.invalid("Wallet file exceeds 4 MiB"), "bounded file read") { _ = try await files.read(oversized) }
    let malformed = f.root.appendingPathComponent("malformed.walletenc")
    try Data("{}".utf8).write(to: malformed)
    try await expectVaultError(.invalid("Malformed wallet envelope"), "malformed file") { _ = try await files.read(malformed) }
}

private func checkOfflineRecovery(_ f: RecoveryFixture) async throws {
    let repository = try f.repository("offline-source", keychain: MemoryKeychain())
    let wallet = try await repository.create(name: "Offline Regtest", descriptors: f.descriptors, authorizations: f.auths, secretMode: .local, cacheMode: nil)
    let cacheRoot = f.root.appendingPathComponent("offline-cache")
    let cache = try EncryptedOfflineCache(root: cacheRoot, coordinator: TestFileCoordinator())
    try await cache.preserve(wallet)
    try await cache.preserve(wallet)
    try require(try await cache.snapshots().count == 1, "offline preservation idempotent")
    let snapshotURL = try await cache.snapshots()[0]
    let fresh = try f.repository("offline-fresh", keychain: MemoryKeychain())
    let stored = try await fresh.files.read(snapshotURL)
    try require(try await fresh.unlock(stored, manual: f.auths[2].secret).payload == wallet.payload, "independent offline recovery through third signer")
    let expectedBytes = try Data(contentsOf: snapshotURL)
    // A changed existing snapshot is retained, never silently overwritten.
    try Data("corrupt synthetic snapshot".utf8).write(to: snapshotURL)
    try await expectVaultError(.conflict, "offline snapshot conflict") { try await cache.preserve(wallet) }
    try require(try Data(contentsOf: snapshotURL) != expectedBytes, "conflicting snapshot preserved for review")
    let locations = WalletLocations(applicationSupport: f.root.appendingPathComponent("scan-support"), documents: f.root.appendingPathComponent("scan-documents"))
    try FileManager.default.createDirectory(at: locations.local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: locations.local)
    try require(locations.scan().inaccessible == [locations.local], "inaccessible predetermined folder is reported")
}

private func checkRepositoryImportAndFailures(_ f: RecoveryFixture) async throws {
    let memory = MemoryKeychain()
    let repository = try f.repository("create-failures", keychain: memory)
    try await expectVaultError(.invalid("Give the wallet a name"), "empty wallet name") { _ = try await repository.create(name: "  ", descriptors: f.descriptors, authorizations: f.auths, secretMode: .local, cacheMode: nil) }
    await memory.failSave(in: .local)
    try await expectVaultError(.keychain(-34018), "creation secret write failure") { _ = try await repository.create(name: "Fixture", descriptors: f.descriptors, authorizations: f.auths, secretMode: .local, cacheMode: .local) }
    try require(try await repository.files.list().isEmpty, "failed secret save never creates a wallet file")
    await memory.failSave(in: nil)
    let wallet = try await repository.create(name: "  Fixture  ", descriptors: f.descriptors, authorizations: f.auths, secretMode: .local, cacheMode: .local)
    try require(wallet.payload.name == "Fixture", "created name is normalized")
    let duplicate = try await repository.create(name: "Ignored new name", descriptors: f.descriptors, authorizations: f.auths, secretMode: .synchronized, cacheMode: .synchronized)
    try require(duplicate.payload.walletId == wallet.payload.walletId, "authenticated equivalent import reuses wallet identity")
    let importedRepository = try f.repository("import-destination", keychain: MemoryKeychain())
    let imported = try await importedRepository.imported(wallet.stored, dek: wallet.dek)
    try require(imported.payload == wallet.payload && imported.stored.url != wallet.stored.url, "encrypted import preserves payload in destination")
    try await expectVaultError(.missingKey, "import does not implicitly cache keys") { _ = try await importedRepository.unlock(imported.stored) }
    try require(try await importedRepository.unlock(imported.stored, manual: f.auths[0].secret).payload == wallet.payload, "import recovery needs a valid signer")
    let failedFiles = try EncryptedFileStore(directory: f.root.appendingPathComponent("failed-coordination"), coordinator: FailedCoordinator())
    let failedRepository = WalletRepository(files: failedFiles, keychain: MemoryKeychain())
    try await expectVaultError(.unavailable("Synthetic coordination failure"), "coordinator write failure") { _ = try await failedRepository.imported(wallet.stored, dek: wallet.dek) }
    try require(try await failedFiles.list().isEmpty, "coordination failure never falls back to uncoordinated writes")
    try await expectVaultError(.unavailable("Synthetic coordination failure"), "coordinator read failure") { _ = try await failedFiles.read(wallet.stored.url) }
}
