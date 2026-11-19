import Foundation

public enum VaultError: Error, LocalizedError, Equatable {
    case invalid(String), authentication, unsupportedVersion, conflict, missingKey, keychain(Int32), unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s): return s
        case .authentication: return "The secret is incorrect or the wallet file failed authentication."
        case .unsupportedVersion: return "This wallet format is not supported. Update the app before opening it."
        case .conflict: return "The wallet changed on another device. Both versions have been preserved."
        case .missingKey: return "No cached key is available. Recover with a BIP-85 HEX secret."
        case .keychain(let code): return "Keychain operation failed (\(code)). Check device unlock, signing and access-group entitlements."
        }
    }
}
public enum WalletNetwork: String, Codable, CaseIterable, Sendable { case mainnet, testnet, signet, regtest }
public struct Cosigner: Codable, Equatable, Sendable {
    public let xpub: String
    public let fingerprint: String
    public let origin: String
}
public struct ValidatedDescriptors: Codable, Equatable, Sendable {
    public let receive: String
    public let change: String
    public let sourceReceive: String
    public let sourceChange: String?
    public let network: WalletNetwork
    public let threshold: Int
    public let scriptType: String
    public let cosigners: [Cosigner]
    public let canonicalIdentity: String
}
public struct WalletPayload: Codable, Equatable, Sendable {
    public var walletId: UUID
    public var name: String
    public var descriptors: ValidatedDescriptors
    public var createdAt: Date
    public var modifiedAt: Date
    public init(walletId: UUID = UUID(), name: String, descriptors: ValidatedDescriptors) {
        self.walletId = walletId; self.name = name; self.descriptors = descriptors
        createdAt = Date(); modifiedAt = createdAt
    }
}
public protocol DescriptorValidating: Sendable {
    func validate(receive: String, change: String?, network: WalletNetwork) throws -> ValidatedDescriptors
}
@_silgen_name("nv_descriptor_validate") private func nativeValidate(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("nv_descriptor_free") private func nativeFree(_ output: UnsafeMutablePointer<CChar>)
public struct DescriptorValidator: DescriptorValidating {
    public init() {}
    public func validate(receive: String, change: String?, network: WalletNetwork) throws -> ValidatedDescriptors {
        struct Request: Encodable { let receive: String; let change: String?; let network: WalletNetwork }
        struct Response: Decodable { let value: ValidatedDescriptors?; let error: String? }
        guard !receive.utf8.contains(0), !(change?.utf8.contains(0) ?? false), receive.utf8.count <= 131072, (change?.utf8.count ?? 0) <= 131072 else { throw VaultError.invalid("Invalid descriptor size or encoding") }
        let request = try JSONEncoder().encode(Request(receive: receive, change: change, network: network))
        let response = String(decoding: request, as: UTF8.self).withCString { nativeValidate($0) }
        guard let response else { throw VaultError.invalid("Descriptor validation failed") }
        defer { nativeFree(response) }
        let result = try JSONDecoder().decode(Response.self, from: Data(String(cString: response).utf8))
        guard let value = result.value else { throw VaultError.invalid(result.error ?? "Invalid descriptor") }
        return value
    }
}
