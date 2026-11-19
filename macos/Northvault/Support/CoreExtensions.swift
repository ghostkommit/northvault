import Foundation

// Conformances and labels for the uniffi-generated types (Generated/northvault_core.swift).

extension Account: Identifiable {}

extension WalletTransaction: Identifiable {
    public var id: String { "\(accountId):\(txid)" }
    var isIncoming: Bool { amountSats > 0 }
    var isPending: Bool { confirmations == 0 }
}

extension Utxo: Identifiable {
    public var id: String { "\(txid):\(vout)" }
}

extension AddressInfo: Identifiable {
    public var id: String { derivationPath }
}

extension TimeRange {
    static let all: [TimeRange] = [.week, .month, .quarter, .year, .allTime]

    var shortLabel: String {
        switch self {
        case .week: "1W"
        case .month: "1M"
        case .quarter: "3M"
        case .year: "1Y"
        case .allTime: "All"
        }
    }

    var phrase: String {
        switch self {
        case .week: "past week"
        case .month: "past month"
        case .quarter: "past 3 months"
        case .year: "past year"
        case .allTime: "entire history"
        }
    }
}

extension FeeLevel {
    var title: String {
        switch self {
        case .economy: "Economy"
        case .standard: "Standard"
        case .priority: "Priority"
        }
    }
}

extension FeeEstimate {
    var etaText: String {
        switch targetBlocks {
        case ...1: "Next block"
        case ...6: "About an hour"
        default: "About a day"
        }
    }
}

extension Utxo {
    var outPoint: OutPoint { OutPoint(txid: txid, vout: vout) }
}

extension ScriptType {
    static let singleSig: [ScriptType] = [.p2wpkh, .p2tr, .p2shP2wpkh, .p2pkh]
    static let multisig: [ScriptType] = [.p2wsh, .p2shP2wsh, .p2sh]

    var label: String {
        switch self {
        case .p2pkh: "P2PKH"
        case .p2shP2wpkh: "P2SH-P2WPKH"
        case .p2wpkh: "P2WPKH"
        case .p2tr: "P2TR"
        case .p2sh: "P2SH"
        case .p2shP2wsh: "P2SH-P2WSH"
        case .p2wsh: "P2WSH"
        }
    }

    /// Names in the script type picker.
    var title: String {
        switch self {
        case .p2pkh: "Legacy (P2PKH)"
        case .p2shP2wpkh: "Nested SegWit (P2SH-P2WPKH)"
        case .p2wpkh: "Native SegWit (P2WPKH)"
        case .p2tr: "Taproot (P2TR)"
        case .p2sh: "Legacy (P2SH)"
        case .p2shP2wsh: "Nested SegWit (P2SH-P2WSH)"
        case .p2wsh: "Native SegWit (P2WSH)"
        }
    }
}

extension Network {
    static let all: [Network] = [.bitcoin, .testnet4, .signet, .testnet, .regtest]

    var title: String {
        switch self {
        case .bitcoin: "Mainnet"
        case .testnet: "Testnet3"
        case .testnet4: "Testnet4"
        case .signet: "Signet"
        case .regtest: "Regtest"
        }
    }

    /// Stable string for UserDefaults.
    var key: String {
        switch self {
        case .bitcoin: "bitcoin"
        case .testnet: "testnet"
        case .testnet4: "testnet4"
        case .signet: "signet"
        case .regtest: "regtest"
        }
    }

    init?(key: String) {
        guard let match = Network.all.first(where: { $0.key == key }) else { return nil }
        self = match
    }
}

extension DeviceKind {
    var title: String {
        switch self {
        case .coldcard: "Coldcard"
        case .trezor: "Trezor"
        case .jade: "Jade"
        }
    }
}

extension HardwareDevice: Identifiable {}

extension ExportFormat {
    var title: String {
        switch self {
        case .descriptor: "Output descriptor"
        case .coldcardMultisig: "Multisig setup file (Coldcard, Jade)"
        case .bsms: "BSMS descriptor record (BIP129)"
        case .specterDiy: "Wallet file (Specter DIY)"
        case .labels: "Labels (BIP329)"
        }
    }

    var fileName: String {
        switch self {
        case .descriptor: "descriptor.txt"
        case .coldcardMultisig: "multisig.txt"
        case .bsms: "wallet.bsms"
        case .specterDiy: "specter-wallet.txt"
        case .labels: "labels.jsonl"
        }
    }
}

extension WalletError {
    /// User-facing message (the generated errorDescription is debug output).
    var message: String {
        switch self {
        case .UnknownAccount: "This account no longer exists."
        case .InvalidAddress: "That doesn’t look like a valid Bitcoin address."
        case .WrongNetwork: "That address or key is for a different Bitcoin network."
        case .ZeroAmount: "Enter an amount greater than zero."
        case .InsufficientFunds: "Amount plus fee is more than the spendable balance."
        case .FeeTooHigh: "That fee rate is unreasonably high."
        case .PrivateKeyNotAllowed: "Private keys can’t be imported. Northvault is watch-only."
        case .InvalidConfig(let message): message.prefix(1).uppercased() + message.dropFirst() + "."
        case .Interop(let message): "Couldn’t read this file: \(message)."
        case .PsbtMismatch: "The signed transaction doesn’t match the one you created. Don’t broadcast it."
        case .NotEnoughSignatures(let have, let need): "\(have) of \(need) signatures so far."
        case .AddressMismatch(let shown): "The device showed a different address (\(shown)). Don’t use this address."
        case .Device(let message): message
        case .Server(let message): "Electrum server: \(message)"
        case .NotSupported(let message): message.prefix(1).uppercased() + message.dropFirst() + "."
        case .Backend(let message): message
        }
    }
}

extension Error {
    /// Message for alerts, whatever the error type.
    var userMessage: String {
        (self as? WalletError)?.message ?? localizedDescription
    }
}

extension Date {
    init(unix: Int64) { self.init(timeIntervalSince1970: TimeInterval(unix)) }
}

extension String {
    /// "bc1qxyz…abcd"
    func abbreviated(head: Int, tail: Int) -> String {
        guard count > head + tail + 1 else { return self }
        return "\(prefix(head))…\(suffix(tail))"
    }

    /// Splits into groups of 4 for readable addresses.
    var grouped: String {
        stride(from: 0, to: count, by: 4).map { i -> String in
            let start = index(startIndex, offsetBy: i)
            let end = index(start, offsetBy: 4, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }.joined(separator: " ")
    }
}
