import AppKit
import Vision

// Real CoreImage + EFQRCode + Vision + UniFFI/BC-UR integration. Synthetic only.
@main
struct QRChecks {
    static let logo = URL(fileURLWithPath: "macos/Northvault/Resources/NorthvaultLogo.png")

    static func main() throws {
        let wallet = WalletService.newSample()
        let accounts = wallet.accounts()
        var checked = 0
        for account in accounts {
            for offset: UInt32 in [0, 1, 7] {
                let address = try wallet.nextReceiveAddress(accountId: account.id, offset: offset).address
                let payload = "bitcoin:\(address)"
                for size in [360, 720] {
                    let image = try QRCodeRenderer.render(payload, dimension: size, logoURL: logo)
                    let decoded = try decode(image)
                    precondition(decoded == payload)
                    try checkPixels(image)
                    checked += 1
                    if checked == 1 {
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                            .write(to: URL(fileURLWithPath: "macos/build/qr-integration.png"))
                    }
                }
            }
        }
        // Preserve arbitrary UTF-8 for future payloads as well as BIP21 parameters.
        for payload in ["Northvault — café", "bitcoin:bc1qexample?amount=0.001&label=Test%20wallet",
                        String(repeating: "x", count: QRCodeRenderer.maxPayloadBytes)] {
            let image = try QRCodeRenderer.render(payload, logoURL: logo)
            let decoded = try decode(image)
            precondition(decoded == payload)
            checked += 1
        }
        for inputs in [1, 10] {
            let original = syntheticPSBT(inputs: inputs)
            let parts = try wallet.psbtToUrParts(psbt: original)
            precondition(inputs == 1 ? parts.count == 1 : parts.count > 1)
            try QRCodeRenderer.validate(parts)
            let decoder = UrDecoder()
            for part in parts {
                let image = try QRCodeRenderer.render(part, logoURL: logo)
                let decoded = try decode(image)
                precondition(decoded == part)
                // The modal shows a 420-point code on a standard-density display.
                let display = CGContext(data: nil, width: 420, height: 420, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                display.interpolationQuality = .none
                display.draw(image, in: CGRect(x: 0, y: 0, width: 420, height: 420))
                let displayedPayload = try decode(display.makeImage()!)
                precondition(displayedPayload == part, "Displayed transaction QR must remain readable")
                _ = try decoder.receive(part: decoded)
                try checkPixels(image)
                checked += 1
            }
            let result = try decoder.result()
            precondition(result == original, "QR scan must reproduce the exact PSBT")
            let plainDecoder = UrDecoder()
            _ = try plainDecoder.receive(part: original)
            let plainResult = try plainDecoder.result()
            precondition(plainResult == original, "Plain base64 QR must preserve case")
        }
        try fails(.empty) { _ = try QRCodeRenderer.render("", logoURL: logo) }
        try fails(.tooLarge) { _ = try QRCodeRenderer.render(String(repeating: "x", count: 1001), logoURL: logo) }
        try fails(.tooLarge) { _ = try QRCodeRenderer.render("small", dimension: 10, logoURL: logo) }
        try fails(.missingLogo) {
            _ = try QRCodeRenderer.render("test", logoURL: URL(fileURLWithPath: "/nonexistent/northvault-logo.png"))
        }
        try fails(.empty) { try QRCodeRenderer.validate([]) }
        try fails(.empty) { try QRCodeRenderer.validate(["valid", ""]) }
        try fails(.tooLarge) { try QRCodeRenderer.validate(Array(repeating: "test", count: 129)) }
        print("QR integration passed: \(checked) branded images decoded exactly; BIP21, UTF-8, single/multipart PSBT round trips, and failure paths")
    }

    static func decode(_ image: CGImage) throws -> String {
        guard let payload = try QRImageDecoder.payloads(in: image).first else { throw QRCodeError.unreadable }
        return payload
    }

    static func checkPixels(_ image: CGImage) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let corner = rep.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        precondition(corner.redComponent > 0.99 && corner.greenComponent > 0.99 && corner.blueComponent > 0.99,
                     "QR quiet zone must be white")
        var colored = 0
        let side = image.width
        for y in (side * 45 / 100)..<(side * 55 / 100) {
            for x in (side * 45 / 100)..<(side * 55 / 100) {
                let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if abs(color.redComponent - color.blueComponent) > 0.025 { colored += 1 }
            }
        }
        precondition(colored > 10, "Every QR must contain the colored shield, not an empty logo tile")
    }

    static func fails(_ expected: QRCodeError, _ action: () throws -> Void) throws {
        do { try action(); preconditionFailure("Expected a QR error") }
        catch let error as QRCodeError { precondition(error.localizedDescription == expected.localizedDescription) }
    }

    static func syntheticPSBT(inputs: Int) -> String {
        var tx: [UInt8] = [2, 0, 0, 0, UInt8(inputs)]
        for i in 0..<inputs {
            tx += Array(repeating: UInt8(i + 1), count: 32)
            tx += [0, 0, 0, 0, 0, 255, 255, 255, 255]
        }
        tx += [1, 232, 3, 0, 0, 0, 0, 0, 0, 1, 81, 0, 0, 0, 0]
        let length: [UInt8] = tx.count < 253 ? [UInt8(tx.count)] : [253, UInt8(tx.count & 255), UInt8(tx.count >> 8)]
        return Data([112, 115, 98, 116, 255, 1, 0] + length + tx + Array(repeating: 0, count: inputs + 2)).base64EncodedString()
    }
}
