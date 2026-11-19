import Foundation

enum DisplayCurrency: String, CaseIterable, Identifiable {
    case usd = "USD", eur = "EUR", gbp = "GBP", chf = "CHF", jpy = "JPY", btc = "BTC"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .usd: "US dollar"
        case .eur: "Euro"
        case .gbp: "British pound"
        case .chf: "Swiss franc"
        case .jpy: "Japanese yen"
        case .btc: "Bitcoin only"
        }
    }

    /// The Rust-side fiat currency, or nil when showing everything in BTC.
    var fiat: FiatCurrency? {
        switch self {
        case .usd: .usd
        case .eur: .eur
        case .gbp: .gbp
        case .chf: .chf
        case .jpy: .jpy
        case .btc: nil
        }
    }
}

enum BitcoinUnit: String, CaseIterable, Identifiable {
    case btc = "BTC", sats

    var id: String { rawValue }

    /// String suitable for an amount text field.
    func inputString(_ sats: UInt64) -> String {
        switch self {
        case .btc: String(format: "%.8f", Double(sats) / 100_000_000)
        case .sats: String(sats)
        }
    }

    /// Parses user input into sats. Uses Decimal to avoid floating-point drift.
    func parse(_ text: String) -> UInt64 {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return 0 }
        let sats = self == .btc ? value * 100_000_000 : value
        var rounded = Decimal()
        var input = sats
        NSDecimalRound(&rounded, &input, 0, .plain)
        return NSDecimalNumber(decimal: rounded).uint64Value
    }
}

/// All amount formatting in one place. Built from AppState settings.
struct MoneyFormat {
    var currency: DisplayCurrency
    var unit: BitcoinUnit
    var hidden: Bool
    /// USD -> display currency (1 for USD and BTC).
    var usdToCurrency: Double

    static let mask = "••••••"

    func bitcoin(_ sats: Int64, signed: Bool = false) -> String {
        guard !hidden else { return Self.mask }
        let magnitude = sats.magnitude
        let body = switch unit {
        case .btc: String(format: "%.8f BTC", Double(magnitude) / 100_000_000)
        case .sats: "\(magnitude.formatted(.number)) sats"
        }
        return sign(sats < 0, signed) + body
    }

    func bitcoin(_ sats: UInt64) -> String { bitcoin(Int64(sats)) }

    /// Numeric value in the display currency (BTC when currency is .btc).
    func amount(sats: Int64, priceUSD: Double) -> Double {
        let btc = Double(sats) / 100_000_000
        return currency == .btc ? btc : btc * priceUSD * usdToCurrency
    }

    /// Primary value in the display currency.
    func value(sats: Int64, priceUSD: Double, signed: Bool = false) -> String {
        if currency == .btc { return bitcoin(sats, signed: signed) }
        guard !hidden else { return Self.mask }
        return number(amount(sats: sats, priceUSD: priceUSD), signed: signed)
    }

    /// Secondary fiat line under a BTC amount; empty when the display currency is BTC.
    func fiatSubtitle(sats: Int64, priceUSD: Double, signed: Bool = false) -> String {
        currency == .btc ? "" : value(sats: sats, priceUSD: priceUSD, signed: signed)
    }

    /// Formats an already-converted number (chart values, deltas).
    func number(_ v: Double, signed: Bool = false) -> String {
        guard !hidden else { return Self.mask }
        let body = currency == .btc
            ? String(format: "%.8f BTC", abs(v))
            : abs(v).formatted(.currency(code: currency.rawValue))
        return sign(v < 0, signed) + body
    }

    /// Compact chart axis label.
    func axis(_ v: Double) -> String {
        guard !hidden else { return "•••" }
        if currency == .btc {
            return v.formatted(.number.precision(.fractionLength(v < 1 ? 4 : 2))) + " BTC"
        }
        // Keep this compatible with the macOS 14 SDK shipped with Xcode 15.
        // An availability check cannot make newer SDK members compile there.
        let (scaled, suffix): (Double, String) = switch abs(v) {
        case 1_000_000_000...: (v / 1_000_000_000, "B")
        case 1_000_000...: (v / 1_000_000, "M")
        case 1_000...: (v / 1_000, "K")
        default: (v, "")
        }
        return scaled.formatted(.currency(code: currency.rawValue).precision(.fractionLength(0...1))) + suffix
    }

    private func sign(_ negative: Bool, _ signed: Bool) -> String {
        negative ? "−" : (signed ? "+" : "")
    }
}
