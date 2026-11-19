import AppKit
import EFQRCode

enum QRCodeError: LocalizedError {
    case empty, tooLarge, missingLogo, rendering, unreadable

    var errorDescription: String? {
        switch self {
        case .empty: return "There is no content to show as a QR code."
        case .tooLarge: return "This content is too large for QR display. Use file export instead."
        case .missingLogo: return "The app logo could not be loaded. Reinstall Northvault and try again."
        case .rendering: return "The QR code could not be generated. Please try again."
        case .unreadable: return "The QR code could not be verified. Use file export or copy the address instead."
        }
    }
}

/// All generated QR images pass through this renderer, including every BC-UR frame.
/// Payloads stay local and are never included in errors or logs.
enum QRCodeRenderer {
    static let maxPayloadBytes = 1_000
    static let maxFrames = 128

    static func render(_ payload: String, dimension: Int = 720, logoURL: URL? = nil) throws -> CGImage {
        guard !payload.isEmpty else { throw QRCodeError.empty }
        guard payload.utf8.count <= maxPayloadBytes, (240...1440).contains(dimension) else {
            throw QRCodeError.tooLarge
        }
        guard let url = logoURL ?? Bundle.main.url(forResource: "NorthvaultLogo", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw QRCodeError.missingLogo }

        let generator = EFQRCodeGenerator(content: payload)
        generator.inputCorrectionLevel = .h
        generator.magnification = EFIntSize(width: 1, height: 1)
        guard let intrinsic = generator.generate() else { throw QRCodeError.rendering }
        // Integer module sizes keep edges crisp. Add four full white modules on
        // each side, in addition to the encoder's existing border.
        let scale = dimension / (intrinsic.width + 8)
        guard scale >= 3 else { throw QRCodeError.tooLarge }
        let codeSide = intrinsic.width * scale
        generator.magnification = EFIntSize(width: scale, height: scale)

        // Small, opaque logo tile: 14% of the code width (under 2% of its area).
        // High correction is necessary but not sufficient: decode the final image.
        let tileSide = max(1, Int(Double(codeSide) * 0.14))
        guard let tile = context(width: tileSide, height: tileSide) else { throw QRCodeError.rendering }
        tile.setFillColor(CGColor(gray: 1, alpha: 1))
        tile.fill(CGRect(x: 0, y: 0, width: tileSide, height: tileSide))
        let inset = max(2, CGFloat(tileSide) * 0.08)
        tile.draw(logo, in: CGRect(x: 0, y: 0, width: tileSide, height: tileSide).insetBy(dx: inset, dy: inset))
        guard let icon = tile.makeImage() else { throw QRCodeError.rendering }
        generator.withIcon(icon, size: EFIntSize(width: tileSide, height: tileSide))
        generator.clearCache() // Regenerate the foreground at the final integer scale.
        guard let code = generator.generate() else { throw QRCodeError.rendering }

        let border = scale * 4
        // Even dimensions also support camera/decoder pixel formats using 2×2 chroma blocks.
        let side = (codeSide + border * 2 + 1) / 2 * 2
        guard let canvas = context(width: side, height: side) else { throw QRCodeError.rendering }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        canvas.interpolationQuality = .none
        canvas.draw(code, in: CGRect(x: border, y: border, width: codeSide, height: codeSide))
        guard let image = canvas.makeImage() else { throw QRCodeError.rendering }
        guard try QRImageDecoder.payloads(in: image).contains(payload) else {
            throw QRCodeError.unreadable
        }
        return image
    }

    static func validate(_ parts: [String]) throws {
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { throw QRCodeError.empty }
        guard parts.count <= maxFrames, parts.allSatisfy({ $0.utf8.count <= maxPayloadBytes }) else {
            throw QRCodeError.tooLarge
        }
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
