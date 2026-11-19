// EFQRCode 6.2.2, Copyright (c) 2017-2021 EyreFree. MIT; see ../../LICENSE.
// Documentation comments omitted; see upstream for API documentation.
import CoreImage
import CoreGraphics
import Foundation

@objcMembers
public class EFQRCodeGenerator: NSObject {
    @inlinable @discardableResult
    public func with<T>(_ keyPath: ReferenceWritableKeyPath<EFQRCodeGenerator, T>,
                        _ newValue: T) -> EFQRCodeGenerator {
        self[keyPath: keyPath] = newValue
        return self
    }
    public var content: String? { didSet { clearCache() } }
    @discardableResult
    public func withContent(_ content: String, encoding: String.Encoding? = nil) -> EFQRCodeGenerator {
        self.content = content
        if let encoding = encoding { return withContentEncoding(encoding) }
        return self
    }
    public var contentEncoding: String.Encoding = .utf8 { didSet { clearCache() } }
    @discardableResult
    public func withContentEncoding(_ encoding: String.Encoding) -> EFQRCodeGenerator {
        return with(\.contentEncoding, encoding)
    }
    public var inputCorrectionLevel: EFInputCorrectionLevel = .h { didSet { clearCache() } }
    @discardableResult
    public func withInputCorrectionLevel(_ inputCorrectionLevel: EFInputCorrectionLevel) -> EFQRCodeGenerator {
        return with(\.inputCorrectionLevel, inputCorrectionLevel)
    }
    public var mode: EFQRCodeMode? = nil { didSet { imageQRCode = nil } }
    @discardableResult
    public func withMode(_ mode: EFQRCodeMode?) -> EFQRCodeGenerator { return with(\.mode, mode) }
    public var size: EFIntSize = EFIntSize(width: 256, height: 256) { didSet { imageQRCode = nil } }
    @discardableResult
    public func withSize(_ size: EFIntSize) -> EFQRCodeGenerator { return with(\.size, size) }
    public var magnification: EFIntSize? { didSet { imageQRCode = nil } }
    @discardableResult
    public func withMagnification(_ magnification: EFIntSize?) -> EFQRCodeGenerator {
        return with(\.magnification, magnification)
    }
    public var backgroundColor: CGColor = CGColor.white()! { didSet { imageQRCode = nil } }
    public var foregroundColor: CGColor = CGColor.black()! { didSet { imageQRCode = nil } }
    @discardableResult @objc(withCIColorsForBackgroundColor:foregroundColor:)
    public func withColors(backgroundColor: CIColor, foregroundColor: CIColor) -> EFQRCodeGenerator {
        return withColors(backgroundColor: backgroundColor.cgColor() ?? CGColor.white()!,
                          foregroundColor: foregroundColor.cgColor() ?? CGColor.black()!)
    }
    @discardableResult @objc(withCGColorsForBackgroundColor:foregroundColor:)
    public func withColors(backgroundColor: CGColor, foregroundColor: CGColor) -> EFQRCodeGenerator {
        return self.with(\.backgroundColor, backgroundColor).with(\.foregroundColor, foregroundColor)
    }
    public var icon: CGImage? = nil { didSet { imageQRCode = nil } }
    public var iconSize: EFIntSize? = nil { didSet { imageQRCode = nil } }
    @discardableResult
    public func withIcon(_ icon: CGImage?, size: EFIntSize?) -> EFQRCodeGenerator {
        return self.with(\.icon, icon).with(\.iconSize, size)
    }
    public var watermark: CGImage? = nil { didSet { imageQRCode = nil } }
    public var watermarkMode: EFWatermarkMode = .scaleAspectFill { didSet { imageQRCode = nil } }
    @discardableResult
    public func withWatermark(_ watermark: CGImage?, mode: EFWatermarkMode? = nil) -> EFQRCodeGenerator {
        self.watermark = watermark
        if let mode = mode { self.watermarkMode = mode }
        return self
    }
    public var pointOffset: CGFloat = 0 { didSet { imageQRCode = nil } }
    @discardableResult
    public func withPointOffset(_ pointOffset: CGFloat) -> EFQRCodeGenerator { return with(\.pointOffset, pointOffset) }
    public var isWatermarkOpaque: Bool = false { didSet { imageQRCode = nil } }
    @discardableResult
    public func withOpaqueWatermark(_ isWatermarkOpaque: Bool = true) -> EFQRCodeGenerator {
        return with(\.isWatermarkOpaque, isWatermarkOpaque)
    }
    @discardableResult
    public func withTransparentWatermark(_ isTransparent: Bool = true) -> EFQRCodeGenerator {
        return withOpaqueWatermark(!isTransparent)
    }
    public var pointStyle: EFPointStyle = EFSquarePointStyle.square { didSet { imageQRCode = nil } }
    @discardableResult
    public func withPointStyle(_ pointStyle: EFPointStyle) -> EFQRCodeGenerator { return with(\.pointStyle, pointStyle) }
    public var isTimingPointStatic: Bool = true { didSet { imageQRCode = nil } }
    @discardableResult
    public func withStaticTimingPoint(_ isStatic: Bool = true) -> EFQRCodeGenerator { return with(\.isTimingPointStatic, isStatic) }
    @discardableResult
    public func withStyledTimingPoint(_ ignoreTiming: Bool = true) -> EFQRCodeGenerator { return withStaticTimingPoint(!ignoreTiming) }
    private var imageCodes: [[Bool]]? {
        didSet { frontTransparentQRCodeImage = nil; frontQRCodeImage = nil }
    }
    private var frontTransparentQRCodeImage: CGImage?
    private var frontQRCodeImage: CGImage?
    private var imageQRCode: CGImage?
    private var minSuitableSize: EFIntSize!
    public func clearCache() { imageCodes = nil; imageQRCode = nil }
    public init(content: String, encoding: String.Encoding = .utf8,
                size: EFIntSize = EFIntSize(width: 256, height: 256)) {
        self.content = content
        self.contentEncoding = encoding
        self.size = size
    }
    public func generate() -> CGImage? {
        if nil == imageQRCode { imageQRCode = createImageQRCode() }
        return imageQRCode
    }
    private func createImageQRCode() -> CGImage? {
        var finalSize = self.size
        let finalBackgroundColor = getBackgroundColor()
        let finalForegroundColor = getForegroundColor()
        let finalIcon = self.icon
        let finalIconSize = self.iconSize
        let finalWatermark = self.watermark
        let finalWatermarkMode = self.watermarkMode
        guard let codes = generateCodes() else { return nil }
        if let tryMagnification = magnification {
            finalSize = EFIntSize(width: tryMagnification.width * codes.count,
                                  height: tryMagnification.height * codes.count)
        }
        var result: CGImage?
        if let context = createContext(size: finalSize) {
            minSuitableSize = EFIntSize(
                width: minSuitableSize(greaterThanOrEqualTo: finalSize.width.cgFloat) ?? finalSize.width,
                height: minSuitableSize(greaterThanOrEqualTo: finalSize.height.cgFloat) ?? finalSize.height)
            if let tryWatermark = finalWatermark {
                drawWatermarkImage(context: context, image: tryWatermark, colorBack: finalBackgroundColor,
                                   mode: finalWatermarkMode, size: finalSize.cgSize)
            } else {
                context.setFillColor(finalBackgroundColor)
                context.fill(CGRect(origin: .zero, size: finalSize.cgSize))
            }
            if let tryFrontImage = { () -> CGImage? in
                if finalWatermark != nil {
                    if let tryFrontTransparentQRCodeImage = frontTransparentQRCodeImage { return tryFrontTransparentQRCodeImage }
                    frontTransparentQRCodeImage = createTransparentQRCodeImage(from: codes,
                        colorBack: finalBackgroundColor, colorFront: finalForegroundColor, size: minSuitableSize)
                    return frontTransparentQRCodeImage
                } else {
                    if let tryFrontQRCodeImage = frontQRCodeImage { return tryFrontQRCodeImage }
                    frontQRCodeImage = createQRCodeImage(codes: codes,
                        colorBack: finalBackgroundColor, colorFront: finalForegroundColor, size: minSuitableSize)
                    return frontQRCodeImage
                }
            }() {
                context.draw(tryFrontImage, in: CGRect(origin: .zero, size: finalSize.cgSize))
            }
            if let tryIcon = finalIcon {
                var finalIconSizeWidth = finalSize.width.cgFloat * 0.2
                var finalIconSizeHeight = finalSize.height.cgFloat * 0.2
                if let tryFinalIconSize = finalIconSize {
                    finalIconSizeWidth = tryFinalIconSize.width.cgFloat
                    finalIconSizeHeight = tryFinalIconSize.height.cgFloat
                }
                let maxLength = [CGFloat(0.2), 0.3, 0.4, 0.5][inputCorrectionLevel.rawValue] * finalSize.width.cgFloat
                if finalIconSizeWidth > maxLength {
                    finalIconSizeWidth = maxLength
                    print("Warning: icon width too big, it has been changed.")
                }
                if finalIconSizeHeight > maxLength {
                    finalIconSizeHeight = maxLength
                    print("Warning: icon height too big, it has been changed.")
                }
                let iconSize = EFIntSize(width: Int(finalIconSizeWidth), height: Int(finalIconSizeHeight))
                drawIcon(context: context, icon: tryIcon, size: iconSize)
            }
            result = context.makeImage()
        }
        switch mode {
        case .grayscale?:
            if let tryModeImage = result?.grayscale { result = tryModeImage }
        case .binarization(let threshold)?:
            if let tryModeImage = result?.binarization(threshold: threshold,
                foregroundColor: foregroundColor, backgroundColor: backgroundColor) { result = tryModeImage }
        case nil, EFQRCodeMode.none?: break
        }
        return result
    }
    private func getForegroundColor() -> CGColor {
        switch mode { case .binarization: return .black()!; default: return foregroundColor }
    }
    private func getBackgroundColor() -> CGColor {
        switch mode { case .binarization: return .white()!; default: return backgroundColor }
    }
    private func createQRCodeImage(codes: [[Bool]], colorBack: CIColor, colorFront: CIColor, size: EFIntSize) -> CGImage? {
        guard let colorCGFront = colorFront.cgColor() else { return nil }
        return createQRCodeImage(codes: codes, colorFront: colorCGFront, size: size)
    }
    private func createQRCodeImage(codes: [[Bool]], colorBack colorCGBack: CGColor? = nil,
                                   colorFront colorCGFront: CGColor, size: EFIntSize) -> CGImage? {
        let codeSize = codes.count
        let scaleX = size.width.cgFloat / CGFloat(codeSize)
        let scaleY = size.height.cgFloat / CGFloat(codeSize)
        if scaleX < 1.0 || scaleY < 1.0 { print("Warning: Size too small.") }
        var points = [CGPoint]()
        if let locations = getAlignmentPatternLocations(version: getVersion(size: codeSize - 2)) {
            for indexX in locations {
                for indexY in locations {
                    let finalX = indexX + 1
                    let finalY = indexY + 1
                    if !((finalX == 7 && finalY == 7) || (finalX == 7 && finalY == (codeSize - 8))
                            || (finalX == (codeSize - 8) && finalY == 7)) {
                        points.append(CGPoint(x: finalX, y: finalY))
                    }
                }
            }
        }
        var result: CGImage?
        if let context = createContext(size: size) {
            context.setFillColor(colorCGFront)
            for indexY in 0 ..< codeSize {
                for indexX in 0 ..< codeSize where codes[indexX][indexY] {
                    let indexXCTM = indexY
                    let indexYCTM = codeSize - indexX - 1
                    let isStaticPoint = isStatic(x: indexX, y: indexY, size: codeSize, APLPoints: points)
                    drawPoint(context: context, rect: CGRect(
                        x: CGFloat(indexXCTM) * scaleX + pointOffset, y: CGFloat(indexYCTM) * scaleY + pointOffset,
                        width: scaleX - 2 * pointOffset, height: scaleY - 2 * pointOffset), isStatic: isStaticPoint)
                }
            }
            result = context.makeImage()
        }
        return result
    }
    private func createTransparentQRCodeImage(from codes: [[Bool]], colorBack: CIColor,
        colorFront: CIColor, size: EFIntSize) -> CGImage? {
        guard let colorCGBack = colorBack.cgColor(), let colorCGFront = colorFront.cgColor() else { return nil }
        return createTransparentQRCodeImage(from: codes, colorBack: colorCGBack, colorFront: colorCGFront, size: size)
    }
    private func createTransparentQRCodeImage(from codes: [[Bool]], colorBack colorCGBack: CGColor,
        colorFront colorCGFront: CGColor, size: EFIntSize) -> CGImage? {
        let codeSize = codes.count
        let scaleX = size.width.cgFloat / CGFloat(codeSize)
        let scaleY = size.height.cgFloat / CGFloat(codeSize)
        if scaleX < 1.0 || scaleY < 1.0 { print("Warning: Size too small.") }
        let pointMinOffsetX = scaleX / 3
        let pointMinOffsetY = scaleY / 3
        let pointWidthOriX = scaleX
        let pointWidthOriY = scaleY
        let pointWidthMinX = scaleX - 2 * pointMinOffsetX
        let pointWidthMinY = scaleY - 2 * pointMinOffsetY
        var points = [CGPoint]()
        if let locations = getAlignmentPatternLocations(version: getVersion(size: codeSize - 2)) {
            for indexX in locations {
                for indexY in locations {
                    let finalX = indexX + 1
                    let finalY = indexY + 1
                    if !((finalX == 7 && finalY == 7) || (finalX == 7 && finalY == (codeSize - 8))
                        || (finalX == (codeSize - 8) && finalY == 7)) { points.append(CGPoint(x: finalX, y: finalY)) }
                }
            }
        }
        var finalImage: CGImage?
        if let context = createContext(size: size) {
            context.setFillColor(colorCGBack)
            for indexY in 0 ..< codeSize {
                for indexX in 0 ..< codeSize where !codes[indexX][indexY] {
                    let indexXCTM = indexY
                    let indexYCTM = codeSize - indexX - 1
                    if isStatic(x: indexX, y: indexY, size: codeSize, APLPoints: points) {
                        drawPoint(context: context, rect: CGRect(x: CGFloat(indexXCTM) * scaleX,
                            y: CGFloat(indexYCTM) * scaleY, width: pointWidthOriX, height: pointWidthOriY), isStatic: true)
                    } else {
                        drawPoint(context: context, rect: CGRect(x: CGFloat(indexXCTM) * scaleX + pointMinOffsetX,
                            y: CGFloat(indexYCTM) * scaleY + pointMinOffsetY, width: pointWidthMinX, height: pointWidthMinY))
                    }
                }
            }
            context.setFillColor(colorCGFront)
            for indexY in 0 ..< codeSize {
                for indexX in 0 ..< codeSize where codes[indexX][indexY] {
                    let indexXCTM = indexY
                    let indexYCTM = codeSize - indexX - 1
                    if isStatic(x: indexX, y: indexY, size: codeSize, APLPoints: points) {
                        drawPoint(context: context, rect: CGRect(x: CGFloat(indexXCTM) * scaleX + pointOffset,
                            y: CGFloat(indexYCTM) * scaleY + pointOffset,
                            width: pointWidthOriX - 2 * pointOffset, height: pointWidthOriY - 2 * pointOffset), isStatic: true)
                    } else {
                        drawPoint(context: context, rect: CGRect(x: CGFloat(indexXCTM) * scaleX + pointMinOffsetX,
                            y: CGFloat(indexYCTM) * scaleY + pointMinOffsetY, width: pointWidthMinX, height: pointWidthMinY))
                    }
                }
            }
            finalImage = context.makeImage()
        }
        return finalImage
    }
    private func drawWatermarkImage(context: CGContext, image: CGImage, colorBack: CIColor,
                                    mode: EFWatermarkMode, size: CGSize) {
        drawWatermarkImage(context: context, image: image, colorBack: colorBack.cgColor(), mode: mode, size: size)
    }
    private func drawWatermarkImage(context: CGContext, image: CGImage, colorBack: CGColor?,
                                    mode: EFWatermarkMode, size: CGSize) {
        if let tryColor = colorBack {
            context.setFillColor(tryColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
        if !isWatermarkOpaque {
            guard let codes = generateCodes() else { return }
            if let tryCGImage = createQRCodeImage(codes: codes, colorBack: getBackgroundColor(),
                colorFront: getForegroundColor(), size: minSuitableSize) {
                context.draw(tryCGImage, in: CGRect(origin: .zero, size: size))
            }
        }
        let imageRect = mode.rectForWatermark(ofSize: CGSize(width: image.width, height: image.height), inCanvasOfSize: size)
        context.draw(image, in: imageRect)
    }
    private func drawIcon(context: CGContext, icon: CGImage, size: EFIntSize) {
        context.draw(icon, in: CGRect(origin: CGPoint(x: CGFloat(context.width - size.width) / 2.0,
            y: CGFloat(context.height - size.height) / 2.0), size: size.cgSize))
    }
    private func drawPoint(context: CGContext, rect: CGRect, isStatic: Bool = false) {
        pointStyle.fillRect(context: context, rect: rect, isStatic: isStatic)
    }
    private func createContext(size: EFIntSize) -> CGContext? {
        return CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
    // Northvault: replace CoreImage pixels with the pinned local QR encoder.
    private func generateCodes() -> [[Bool]]? {
        if let imageCodes { return imageCodes }
        guard let data = content?.data(using: contentEncoding) else { return nil }
        imageCodes = QRMatrixEncoder.encode(data, level: inputCorrectionLevel.rawValue)
        return imageCodes
    }
    private func isStatic(x: Int, y: Int, size: Int, APLPoints: [CGPoint]) -> Bool {
        if x == 0 || y == 0 || x == (size - 1) || y == (size - 1) { return true }
        if (x <= 8 && y <= 8) || (x <= 8 && y >= (size - 9)) || (x >= (size - 9) && y <= 8) { return true }
        if isTimingPointStatic { if x == 7 || y == 7 { return true } }
        return APLPoints.contains { point in
            x >= Int(point.x - 2) && x <= Int(point.x + 2) && y >= Int(point.y - 2) && y <= Int(point.y + 2)
        }
    }
    private func getAlignmentPatternLocations(version: Int) -> [Int]? {
        if version == 1 { return nil }
        let divs = 2 + version / 7
        let size = getSize(version: version)
        let total_dist = size - 7 - 6
        let divisor = 2 * (divs - 1)
        let step = (total_dist + divisor / 2 + 1) / divisor * 2
        var coords = [6]
        coords += (0...(divs - 2)).map { i in size - 7 - (divs - 2 - i) * step }
        return coords
    }
    private func getVersion(size: Int) -> Int { return (size - 21) / 4 + 1 }
    private func getSize(version: Int) -> Int { return 17 + 4 * version }
    public func minMagnification(greaterThanOrEqualTo size: CGFloat) -> Int? {
        guard let codes = generateCodes() else { return nil }
        let finalWatermark = watermark
        let baseMagnification = max(1, Int(size / CGFloat(codes.count)))
        for offset in 0 ... 3 {
            let tempMagnification = baseMagnification + offset
            if CGFloat(tempMagnification * codes.count) >= size {
                if finalWatermark == nil { return tempMagnification }
                else if tempMagnification.isMultiple(of: 3) { return tempMagnification }
            }
        }
        return nil
    }
    public func maxMagnification(lessThanOrEqualTo size: CGFloat) -> Int? {
        guard let codes = generateCodes() else { return nil }
        let finalWatermark = watermark
        let baseMagnification = max(1, Int(size / CGFloat(codes.count)))
        for offset in [0, -1, -2, -3] {
            let tempMagnification = baseMagnification + offset
            if tempMagnification <= 0 { return finalWatermark == nil ? 1 : 3 }
            if CGFloat(tempMagnification * codes.count) <= size {
                if finalWatermark == nil { return tempMagnification }
                else if tempMagnification.isMultiple(of: 3) { return tempMagnification }
            }
        }
        return nil
    }
    private func minSuitableSize(greaterThanOrEqualTo size: CGFloat) -> Int? {
        guard let codes = generateCodes() else { return nil }
        let baseSuitableSize = Int(size)
        for offset in codes.indices {
            let tempSuitableSize = baseSuitableSize + offset
            if tempSuitableSize.isMultiple(of: codes.count) { return tempSuitableSize }
        }
        return nil
    }
}
