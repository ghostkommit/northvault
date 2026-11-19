// EFQRCode 6.2.2, Copyright (c) 2017-2021 EyreFree. MIT; see ../../LICENSE.
// Generator support extracted from the upstream Source files. See README.md.
import Foundation
import CoreGraphics
import CoreImage

extension BinaryInteger { var cgFloat: CGFloat { return CGFloat(self) } }
extension CGColor {
    var rgba: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        var color = self
        if color.colorSpace?.model != .rgb {
            color = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil) ?? color
        }
        if let components = color.components, 4 == color.numberOfComponents {
            return (red: UInt8(components[0] * 255.0), green: UInt8(components[1] * 255.0),
                    blue: UInt8(components[2] * 255.0), alpha: UInt8(components[3] * 255.0))
        } else { return nil }
    }
    static func initWith(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> CGColor? {
        return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, green, blue, alpha])
    }
}
public extension CGColor {
    static func white(_ white: CGFloat = 1.0, alpha: CGFloat = 1.0) -> CGColor? {
        return initWith(red: white, green: white, blue: white, alpha: alpha)
    }
    static func black(_ black: CGFloat = 1.0, alpha: CGFloat = 1.0) -> CGColor? {
        return white(1.0 - black, alpha: alpha)
    }
}
extension CGImage {
    var grayscale: CGImage? {
        guard let context = CGContext(data: nil, width: self.width, height: self.height,
            bitsPerComponent: 8, bytesPerRow: 4 * self.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(self, in: CGRect(origin: .zero, size: CGSize(width: self.width, height: self.height)))
        return context.makeImage()
    }
    func binarization(threshold: CGFloat = 0.5, foregroundColor: CGColor = CGColor.white()!,
                      backgroundColor: CGColor = CGColor.black()!) -> CGImage? {
        let dataSize = self.width * self.height * 4
        var pixelData = [UInt8](repeating: 0, count: Int(dataSize))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let backgroundPixel = backgroundColor.rgba, let foregroundPixel = foregroundColor.rgba,
            let context = CGContext(data: &pixelData, width: self.width, height: self.height,
                bitsPerComponent: 8, bytesPerRow: 4 * self.width, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(self, in: CGRect(x: 0, y: 0, width: self.width, height: self.height))
        for x in 0 ..< self.width {
            for y in 0 ..< self.height {
                let offset = 4 * (x + y * self.width)
                let alpha: CGFloat = CGFloat(pixelData[offset + 3]) / 255.0
                let rgb: CGFloat = CGFloat(pixelData[offset + 0]) + CGFloat(pixelData[offset + 1]) + CGFloat(pixelData[offset + 2])
                let intensity = rgb / 3.0 / 255.0 * alpha + (1.0 - alpha)
                let finalPixel = intensity > threshold ? backgroundPixel : foregroundPixel
                pixelData[offset + 0] = finalPixel.red
                pixelData[offset + 1] = finalPixel.green
                pixelData[offset + 2] = finalPixel.blue
                pixelData[offset + 3] = finalPixel.alpha
            }
        }
        return context.makeImage()
    }

}
extension CIColor {
    func cgColor() -> CGColor? { return CGColor(colorSpace: self.colorSpace, components: self.components) }
}
@objc public enum EFInputCorrectionLevel: Int {
    case l = 0
    case m = 1
    case q = 2
    case h = 3
}
@objcMembers public final class EFIntSize: NSObject {
    public let width: Int
    public let height: Int
    public init(width: Int = 0, height: Int = 0) { self.width = width; self.height = height }
    public convenience init(size: CGSize) { self.init(width: Int(size.width), height: Int(size.height)) }
    public var cgSize: CGSize { return CGSize(width: width, height: height) }
}
@objc public protocol EFPointStyle {
    func fillRect(context: CGContext, rect: CGRect, isStatic: Bool)
}
@objc public class EFSquarePointStyle: NSObject, EFPointStyle {
    public func fillRect(context: CGContext, rect: CGRect, isStatic: Bool) { context.fill(rect) }
}
@objc public class EFCirclePointStyle: NSObject, EFPointStyle {
    public func fillRect(context: CGContext, rect: CGRect, isStatic: Bool) {
        if isStatic { context.fill(rect) } else { context.fillEllipse(in: rect) }
    }
}
@objc public class EFDiamondPointStyle: NSObject, EFPointStyle {
    public func fillRect(context: CGContext, rect: CGRect, isStatic: Bool) {
        if isStatic { context.fill(rect) } else { fillDiamond(context: context, rect: rect) }
    }
    private func fillDiamond(context: CGContext, rect: CGRect) {
        let drawingRect = rect.insetBy(dx: -2, dy: -2)
        let path = CGMutablePath()
        let controlPoint = CGPoint(x: drawingRect.midX, y: drawingRect.midY)
        let startPoint = CGPoint(x: drawingRect.minX, y: drawingRect.midY)
        let otherPoints = [CGPoint(x: drawingRect.midX, y: drawingRect.maxY),
                           CGPoint(x: drawingRect.maxX, y: drawingRect.midY),
                           CGPoint(x: drawingRect.midX, y: drawingRect.minY)]
        path.move(to: startPoint)
        for point in otherPoints { path.addQuadCurve(to: point, control: controlPoint) }
        path.addQuadCurve(to: startPoint, control: controlPoint)
        context.addPath(path)
        context.fillPath()
    }
}
public extension EFPointStyle where Self == EFSquarePointStyle { static var square: Self { .init() } }
public extension EFPointStyle where Self == EFCirclePointStyle { static var circle: Self { .init() } }
public extension EFPointStyle where Self == EFDiamondPointStyle { static var diamond: Self { .init() } }
public enum EFQRCodeMode {
    @available(*, deprecated, message: "Use `nil` instead.") case none
    case grayscale
    case binarization(threshold: CGFloat)
}
@objc public enum EFWatermarkMode: Int {
    case scaleToFill = 0
    case scaleAspectFit = 1
    case scaleAspectFill = 2
    case center = 3
    case top = 4
    case bottom = 5
    case left = 6
    case right = 7
    case topLeft = 8
    case topRight = 9
    case bottomLeft = 10
    case bottomRight = 11
    public func rectForWatermark(ofSize imageSize: CGSize, inCanvasOfSize canvasSize: CGSize) -> CGRect {
        let size = canvasSize
        var finalSize = size
        var finalOrigin = CGPoint.zero
        let imageSize = imageSize
        switch self {
        case .bottom:
            finalSize = imageSize
            finalOrigin = CGPoint(x: (size.width - imageSize.width) / 2.0, y: 0)
        case .bottomLeft:
            finalSize = imageSize
            finalOrigin = .zero
        case .bottomRight:
            finalSize = imageSize
            finalOrigin = CGPoint(x: size.width - imageSize.width, y: 0)
        case .center:
            finalSize = imageSize
            finalOrigin = CGPoint(x: (size.width - imageSize.width) / 2.0, y: (size.height - imageSize.height) / 2.0)
        case .left:
            finalSize = imageSize
            finalOrigin = CGPoint(x: 0, y: (size.height - imageSize.height) / 2.0)
        case .right:
            finalSize = imageSize
            finalOrigin = CGPoint(x: size.width - imageSize.width, y: (size.height - imageSize.height) / 2.0)
        case .top:
            finalSize = imageSize
            finalOrigin = CGPoint(x: (size.width - imageSize.width) / 2.0, y: size.height - imageSize.height)
        case .topLeft:
            finalSize = imageSize
            finalOrigin = CGPoint(x: 0, y: size.height - imageSize.height)
        case .topRight:
            finalSize = imageSize
            finalOrigin = CGPoint(x: size.width - imageSize.width, y: size.height - imageSize.height)
        case .scaleAspectFill:
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            finalSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            finalOrigin = CGPoint(x: (size.width - finalSize.width) / 2.0, y: (size.height - finalSize.height) / 2.0)
        case .scaleAspectFit:
            let scale = max(imageSize.width / size.width, imageSize.height / size.height)
            finalSize = CGSize(width: imageSize.width / scale, height: imageSize.height / scale)
            finalOrigin = CGPoint(x: (size.width - finalSize.width) / 2.0, y: (size.height - finalSize.height) / 2.0)
        case .scaleToFill: break
        }
        return CGRect(origin: finalOrigin, size: finalSize)
    }
}
