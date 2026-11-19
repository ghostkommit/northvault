import SwiftUI

/// Design tokens from the Northvault canvas. Change values here, not in views.
enum Theme {
    // Surfaces
    static let ground = Color(hex: 0x0B0D10)
    static let sidebar = Color(hex: 0x12161B)
    static let surface = Color(hex: 0x12161B)
    static let surfaceInset = Color(hex: 0x0E1114)
    static let surfaceRaised = Color(hex: 0x1A1F26)
    static let border = Color(hex: 0x1F242B)
    static let borderStrong = Color(hex: 0x2A313B)

    // Text (all pass 4.5:1 on `surface`)
    static let text = Color(hex: 0xE7EAEE)
    static let textSecondary = Color(hex: 0xB4BCC6)
    static let textMuted = Color(hex: 0x8B95A3)

    // Semantic
    static let accent = Color(hex: 0xF5A524)
    // Opaque dark accent keeps sidebar selection consistent when focus changes.
    static let sidebarSelection = Color(hex: 0x3F331D)
    static let onAccent = Color(hex: 0x0B0D10)
    static let incoming = Color(hex: 0x6AB0F3)
    static let incomingBg = Color(hex: 0x16263A)
    static let positive = Color(hex: 0x5CCB9A)
    static let negative = Color(hex: 0xF08A6C)
    static let warning = Color(hex: 0xF5C26B)
    static let warningBg = Color(hex: 0x2B2210)

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 10
        static let chip: CGFloat = 6
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    /// SF Mono for amounts, txids and addresses.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
