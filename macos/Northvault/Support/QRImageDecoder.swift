import CoreGraphics
import CoreVideo
import Vision

/// Decode the finished, branded image independently of the QR encoder.
/// Supplying CPU-backed luma avoids CoreImage/IOSurface conversion failures.
enum QRImageDecoder {
    static func payloads(in image: CGImage) throws -> [String] {
        let width = image.width
        let height = image.height
        guard width.isMultiple(of: 2), height.isMultiple(of: 2),
              (2...1440).contains(width), (2...1440).contains(height),
              let context = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw QRCodeError.unreadable }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rgba = context.data?.assumingMemoryBound(to: UInt8.self) else { throw QRCodeError.unreadable }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw QRCodeError.unreadable }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw QRCodeError.unreadable }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw QRCodeError.unreadable
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                luma[row * stride + column] = UInt8((Int(rgba[offset]) + Int(rgba[offset + 1]) + Int(rgba[offset + 2])) / 3)
            }
        }
        // Neutral chroma: QR modules are black/white; logo color is irrelevant to decoding.
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let request = VNDetectBarcodesRequest()
        // Revision 1 is the CPU QR detector; newer revisions require ANE/Metal
        // models even for these already-rasterized images. Keep this intentional.
        request.revision = 1
        request.symbologies = [.qr]
        do { try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request]) }
        catch { throw QRCodeError.unreadable }
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
}
