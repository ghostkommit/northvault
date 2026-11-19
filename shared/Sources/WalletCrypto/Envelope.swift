import Foundation
import CryptoKit
import Security
import WalletModels

public struct BIP85Secret: Sendable {
    private let bytes: Data
    public init(hex: String) throws {
        let chars = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard chars.count == 64 else { throw VaultError.invalid("Enter exactly 64 hexadecimal characters (32 bytes), never a seed phrase or xprv.") }
        var result = Data()
        func digit(_ c: UInt8) -> UInt8? { switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: return nil } }
        for i in stride(from: 0, to: 64, by: 2) {
            guard let a = digit(chars[i]), let b = digit(chars[i+1]) else { throw VaultError.invalid("BIP-85 input must be hexadecimal") }
            result.append(a * 16 + b)
        }
        bytes = result
    }
    public init(data: Data) throws { guard data.count == 32 else { throw VaultError.invalid("Invalid secret length") }; bytes = data }
    public func keychainData() -> Data { bytes }
    var key: SymmetricKey { SymmetricKey(data: bytes) }
}
public struct SignerAuthorization: Sendable {
    public let fingerprint: String
    public let index: UInt32
    public let secret: BIP85Secret
    public let cosignerIndex: Int
    public init(fingerprint: String, index: UInt32 = 0, secret: BIP85Secret, cosignerIndex: Int) {
        self.fingerprint = fingerprint.uppercased(); self.index = index; self.secret = secret; self.cosignerIndex = cosignerIndex
    }
}
public struct SignerKeySlot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var fingerprint: String
    public var cosignerIndex: Int
    public var bip85Index: UInt32
    public var bip85Path: String
    public var kdf: String
    public var hkdfSalt: Data
    public var wrappedDEK: Data
}
public struct WalletEnvelope: Codable, Equatable, Sendable, Identifiable {
    public var formatVersion: Int
    public var walletId: UUID
    public var revision: UInt64
    public var revisionId: UUID
    public var parentRevisionId: UUID?
    public var keyGeneration: UUID
    public var algorithm: String
    public var payload: Data
    public var keySlots: [SignerKeySlot]
    public var id: UUID { walletId }
    public func serialized() throws -> Data { try checked(); let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(self) }
    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw VaultError.invalid("Wallet file exceeds 4 MiB") }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch { throw VaultError.invalid("Malformed wallet envelope") }
        try value.checked(); return value
    }
    public func checked() throws {
        guard formatVersion == 1 else { throw VaultError.unsupportedVersion }
        guard algorithm == "AES-256-GCM", revision > 0, payload.count >= 28, !keySlots.isEmpty, keySlots.count <= 20,
              Set(keySlots.map(\.id)).count == keySlots.count else { throw VaultError.invalid("Invalid envelope metadata") }
        for s in keySlots {
            guard s.hkdfSalt.count == 32, s.wrappedDEK.count == 60, s.kdf == "HKDF-SHA256", s.bip85Index < 0x80000000,
                  s.bip85Path == EnvelopeCrypto.path(s.bip85Index), s.cosignerIndex >= 0, s.cosignerIndex < 20,
                  s.fingerprint.utf8.count == 8, s.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { throw VaultError.invalid("Invalid recovery slot") }
        }
    }
}
public enum EnvelopeCrypto {
    public static func path(_ index: UInt32) -> String { "m/83696968'/128169'/32'/\(index)'" }
    public static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VaultError.unavailable("Secure random generation failed") }; return bytes
    }
    // Stable v1 AAD: each UTF-8/binary field has a UInt64 big-endian byte length.
    private static func framed(_ fields: [Data]) -> Data {
        var result = Data()
        for field in fields { var length = UInt64(field.count).bigEndian; withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }; result.append(field) }
        return result
    }
    private static func strings(_ values: [String]) -> [Data] { values.map { Data($0.utf8) } }
    private static func base(_ e: WalletEnvelope) -> [String] { ["northvault.walletenc", String(e.formatVersion), e.walletId.uuidString.lowercased(), e.keyGeneration.uuidString.lowercased(), e.algorithm] }
    private static func slotFields(_ s: SignerKeySlot) -> [Data] {
        strings([s.id.uuidString.lowercased(), s.fingerprint, String(s.cosignerIndex), s.bip85Path, String(s.bip85Index), s.kdf]) + [s.hkdfSalt]
    }
    private static func slotAAD(_ e: WalletEnvelope, _ s: SignerKeySlot) -> Data { framed(strings(base(e) + ["slot"]) + slotFields(s)) }
    private static func payloadAAD(_ e: WalletEnvelope) -> Data {
        var fields = strings(base(e) + ["payload", String(e.revision), e.revisionId.uuidString.lowercased(), e.parentRevisionId?.uuidString.lowercased() ?? ""])
        for slot in e.keySlots { fields.append(framed(slotFields(slot) + [slot.wrappedDEK])) }
        return framed(fields)
    }
    public static func kek(secret: BIP85Secret, envelope: WalletEnvelope, slot: SignerKeySlot) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, salt: slot.hkdfSalt,
            info: framed(strings(base(envelope) + ["kek", slot.id.uuidString.lowercased()])), outputByteCount: 32)
    }
    private static func seal(_ data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: random(12))
        guard let combined = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: aad).combined else { throw VaultError.authentication }; return combined
    }
    public static func create(_ payload: WalletPayload, authorizations: [SignerAuthorization]) throws -> (WalletEnvelope, Data) {
        let dek = try random(32)
        var e = WalletEnvelope(formatVersion: 1, walletId: payload.walletId, revision: 1, revisionId: UUID(), keyGeneration: UUID(), algorithm: "AES-256-GCM", payload: Data(), keySlots: [])
        for auth in authorizations { try addSlot(&e, payload: payload, dek: dek, auth: auth) }
        e.payload = try seal(JSONEncoder().encode(payload), key: SymmetricKey(data: dek), aad: payloadAAD(e))
        try e.checked(); return (e, dek)
    }
    private static func addSlot(_ e: inout WalletEnvelope, payload: WalletPayload, dek: Data, auth: SignerAuthorization) throws {
        guard auth.index < 0x80000000, payload.descriptors.cosigners.indices.contains(auth.cosignerIndex),
              payload.descriptors.cosigners[auth.cosignerIndex].fingerprint == auth.fingerprint,
              !e.keySlots.contains(where: { $0.cosignerIndex == auth.cosignerIndex }) else { throw VaultError.invalid("Invalid or duplicate signer authorization") }
        var slot = SignerKeySlot(id: UUID(), fingerprint: auth.fingerprint, cosignerIndex: auth.cosignerIndex, bip85Index: auth.index, bip85Path: path(auth.index), kdf: "HKDF-SHA256", hkdfSalt: try random(32), wrappedDEK: Data())
        slot.wrappedDEK = try seal(dek, key: kek(secret: auth.secret, envelope: e, slot: slot), aad: slotAAD(e, slot))
        e.keySlots.append(slot)
    }
    public static func unwrap(_ e: WalletEnvelope, secret: BIP85Secret, slotId: UUID) throws -> Data {
        try e.checked()
        guard let s = e.keySlots.first(where: { $0.id == slotId }) else { throw VaultError.missingKey }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: s.wrappedDEK), using: kek(secret: secret, envelope: e, slot: s), authenticating: slotAAD(e,s)) }
        catch { throw VaultError.authentication }
    }
    public static func decrypt(_ e: WalletEnvelope, dek: Data, validator: any DescriptorValidating = DescriptorValidator()) throws -> WalletPayload {
        try e.checked(); guard dek.count == 32 else { throw VaultError.authentication }
        let payload: WalletPayload
        do { let data = try AES.GCM.open(AES.GCM.SealedBox(combined: e.payload), using: SymmetricKey(data: dek), authenticating: payloadAAD(e)); payload = try JSONDecoder().decode(WalletPayload.self, from: data) }
        catch { throw VaultError.authentication }
        guard payload.walletId == e.walletId, !payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.authentication }
        let d = payload.descriptors
        let validated = try validator.validate(receive: d.sourceReceive, change: d.sourceChange, network: d.network)
        guard validated == d, e.keySlots.allSatisfy({ d.cosigners.indices.contains($0.cosignerIndex) && d.cosigners[$0.cosignerIndex].fingerprint == $0.fingerprint }) else { throw VaultError.authentication }
        return payload
    }
    public static func editSlots(_ old: WalletEnvelope, dek: Data, adding: [SignerAuthorization] = [], removing: Set<UUID> = []) throws -> WalletEnvelope {
        var payload = try decrypt(old, dek: dek); payload.modifiedAt = Date()
        var e = old; e.parentRevisionId = old.revisionId; e.revisionId = UUID(); guard e.revision < UInt64.max else { throw VaultError.invalid("Revision exhausted") }; e.revision += 1
        e.keySlots.removeAll { removing.contains($0.id) }
        for a in adding { try addSlot(&e, payload: payload, dek: dek, auth: a) }
        e.payload = try seal(JSONEncoder().encode(payload), key: SymmetricKey(data: dek), aad: payloadAAD(e)); try e.checked(); return e
    }
    public static func rotate(_ old: WalletEnvelope, dek: Data, retaining: [SignerAuthorization]) throws -> (WalletEnvelope, Data) {
        var payload = try decrypt(old, dek: dek); payload.modifiedAt = Date()
        var (e, newKey) = try create(payload, authorizations: retaining)
        guard old.revision < UInt64.max else { throw VaultError.invalid("Revision exhausted") }
        e.revision = old.revision + 1; e.parentRevisionId = old.revisionId
        e.payload = try seal(JSONEncoder().encode(payload), key: SymmetricKey(data: newKey), aad: payloadAAD(e))
        return (e,newKey)
    }
}
