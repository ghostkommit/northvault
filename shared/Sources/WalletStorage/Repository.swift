import Foundation
import WalletModels
import WalletCrypto

public struct UnlockedWallet: Sendable {
    public var stored: StoredEnvelope
    public var payload: WalletPayload
    public var dek: Data
    public init(stored: StoredEnvelope, payload: WalletPayload, dek: Data) { self.stored = stored; self.payload = payload; self.dek = dek }
}
public actor WalletRepository {
    public let files: EncryptedFileStore
    public let keychain: any WalletKeychainService
    public let secrets: SignerSecretStore
    public init(files: EncryptedFileStore, keychain: any WalletKeychainService) {
        self.files = files; self.keychain = keychain; secrets = SignerSecretStore(keychain: keychain)
    }
    public static func keyID(_ e: WalletEnvelope) -> String { "dek.\(e.walletId.uuidString).\(e.keyGeneration.uuidString)" }
    public func cache(_ wallet: UnlockedWallet, mode: KeyStorageMode) async throws {
        try await keychain.save(wallet.dek, id: Self.keyID(wallet.stored.envelope), mode: mode)
    }
    public func moveCache(_ wallet: UnlockedWallet, from: KeyStorageMode, to: KeyStorageMode) async throws {
        guard from != to else { return }; try await cache(wallet, mode: to)
        try await keychain.delete(id: Self.keyID(wallet.stored.envelope), mode: from)
    }
    public func clearCache(_ envelope: WalletEnvelope, mode: KeyStorageMode) async throws {
        try await keychain.delete(id: Self.keyID(envelope), mode: mode)
    }
    public func hasCachedDEK(_ e: WalletEnvelope) async throws -> Bool {
        for mode in KeyStorageMode.allCases { if try await keychain.load(id: Self.keyID(e), mode: mode) != nil { return true } }; return false
    }
    public func unlock(_ stored: StoredEnvelope, manual: BIP85Secret? = nil) async throws -> UnlockedWallet {
        let e = stored.envelope
        if manual == nil {
            for mode in KeyStorageMode.allCases {
                if let dek = try await keychain.load(id: Self.keyID(e), mode: mode), let payload = try? EnvelopeCrypto.decrypt(e, dek: dek) {
                    return UnlockedWallet(stored: stored, payload: payload, dek: dek)
                }
            }
        }
        let candidates: [BIP85Secret]
        if let manual { candidates = [manual] }
        else { candidates = try await secrets.all().map { try BIP85Secret(data: $0.0.secret) } }
        // Fingerprints never grant access. Try authenticated slots, including collisions.
        for secret in candidates {
            for slot in e.keySlots {
                if let dek = try? EnvelopeCrypto.unwrap(e, secret: secret, slotId: slot.id), let payload = try? EnvelopeCrypto.decrypt(e, dek: dek) {
                    return UnlockedWallet(stored: stored, payload: payload, dek: dek)
                }
            }
        }
        throw manual == nil ? VaultError.missingKey : VaultError.authentication
    }
    public func create(name: String, descriptors: ValidatedDescriptors, authorizations: [SignerAuthorization], secretMode: KeyStorageMode, cacheMode: KeyStorageMode?) async throws -> UnlockedWallet {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.invalid("Give the wallet a name") }
        // Reuse authenticated existing imports. Locked files remain candidates for later reconciliation.
        for url in try await files.list() where !url.lastPathComponent.contains(".previous-") {
            guard let record = try? await files.read(url) else { continue }
            var candidate = try? await unlock(record)
            for auth in authorizations where candidate == nil {
                candidate = try? await unlock(record, manual: auth.secret)
            }
            if let existing = candidate, existing.payload.descriptors.canonicalIdentity == descriptors.canonicalIdentity {
                for auth in authorizations where record.envelope.keySlots.contains(where: {
                    (try? EnvelopeCrypto.unwrap(record.envelope, secret: auth.secret, slotId: $0.id)) == existing.dek
                }) { try await secrets.save(auth, mode: secretMode) }
                if let cacheMode { try await cache(existing, mode: cacheMode) }
                return existing
            }
        }
        let payload = WalletPayload(name: name.trimmingCharacters(in: .whitespacesAndNewlines), descriptors: descriptors)
        let (envelope,dek) = try EnvelopeCrypto.create(payload, authorizations: authorizations)
        // Verify every recovery slot before committing any file.
        for (a,s) in zip(authorizations,envelope.keySlots) {
            let recovered = try EnvelopeCrypto.unwrap(envelope, secret: a.secret, slotId: s.id)
            _ = try EnvelopeCrypto.decrypt(envelope, dek: recovered)
        }
        for a in authorizations { try await secrets.save(a, mode: secretMode) }
        let stored = try await files.save(envelope, dek: dek)
        let result = UnlockedWallet(stored: stored, payload: payload, dek: dek)
        if let cacheMode { try await cache(result, mode: cacheMode) }
        return result
    }
    public func imported(_ source: StoredEnvelope, dek: Data) async throws -> UnlockedWallet {
        let payload = try EnvelopeCrypto.decrypt(source.envelope, dek: dek)
        let stored = try await files.save(source.envelope, dek: dek)
        return UnlockedWallet(stored: stored, payload: payload, dek: dek)
    }
    public func changeSlots(_ wallet: UnlockedWallet, adding: [SignerAuthorization], removing: Set<UUID>, secretMode: KeyStorageMode) async throws -> UnlockedWallet {
        let e = try EnvelopeCrypto.editSlots(wallet.stored.envelope, dek: wallet.dek, adding: adding, removing: removing)
        for a in adding { try await secrets.save(a, mode: secretMode) }
        let stored = try await files.save(e, expected: wallet.stored, dek: wallet.dek)
        return UnlockedWallet(stored: stored, payload: try EnvelopeCrypto.decrypt(e, dek: wallet.dek), dek: wallet.dek)
    }
    public func rotate(_ wallet: UnlockedWallet, retaining indices: Set<Int>, supplied: [SignerAuthorization]) async throws -> UnlockedWallet {
        guard !indices.isEmpty else { throw VaultError.invalid("Keep at least one recovery signer") }
        let e = wallet.stored.envelope
        var authorizations: [SignerAuthorization] = []
        let cached = try await secrets.all()
        for index in indices.sorted() {
            guard let slot = e.keySlots.first(where: { $0.cosignerIndex == index }) else { throw VaultError.invalid("Retained signer has no existing slot; add it before rotating") }
            let candidates = supplied.filter { $0.cosignerIndex == index }.map(\.secret) + (try cached.map { try BIP85Secret(data: $0.0.secret) })
            guard let secret = candidates.first(where: { (try? EnvelopeCrypto.unwrap(e, secret: $0, slotId: slot.id)) == wallet.dek }) else { throw VaultError.invalid("Supply the BIP-85 secret for retained signer \(index + 1); no signer will be silently removed.") }
            authorizations.append(SignerAuthorization(fingerprint: slot.fingerprint, index: slot.bip85Index, secret: secret, cosignerIndex: index))
        }
        let (next,key) = try EnvelopeCrypto.rotate(e, dek: wallet.dek, retaining: authorizations)
        let stored = try await files.save(next, expected: wallet.stored, dek: key)
        return UnlockedWallet(stored: stored, payload: try EnvelopeCrypto.decrypt(next, dek: key), dek: key)
    }
    public static func duplicateGroups(_ wallets: [UnlockedWallet]) -> [[UnlockedWallet]] {
        Dictionary(grouping: wallets, by: { $0.payload.descriptors.canonicalIdentity }).values.map { group in
            group.sorted { $0.payload.walletId.uuidString < $1.payload.walletId.uuidString }
        }.sorted { ($0.first?.payload.walletId.uuidString ?? "") < ($1.first?.payload.walletId.uuidString ?? "") }
    }
}
