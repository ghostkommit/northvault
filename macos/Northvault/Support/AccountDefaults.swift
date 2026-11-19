import Foundation

/// A small northern-landscape name generator; names stay editable and avoid collisions.
enum AccountDefaults {
    static func suggestedName(device: HardwareDevice?, existing: [String]) -> String {
        let skies = ["Aurora", "Polar", "Silver", "Midnight", "Amber", "Quiet", "Northern", "Starlit"]
        let places = ["Harbor", "Summit", "Fjord", "Grove", "Beacon", "Cove", "Ridge", "Haven"]
        let base = device.map { "\($0.model) Vault" }
            ?? "\(skies.randomElement()!) \(places.randomElement()!)"
        return unique(base, existing: existing)
    }

    static func unique(_ base: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}
