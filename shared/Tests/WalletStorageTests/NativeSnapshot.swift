#if os(macOS)
import SwiftUI
import AppKit

/// Test-only native rendering and independent pixel recognition. Never initialize
/// this with a production wallet; callers supply isolated synthetic models.
@MainActor final class NativeSnapshot {
    private static var initializedApplication = false
    private let host: NSHostingView<AnyView>
    private let window: NSWindow
    private var nextEventNumber = 1

    init<V: View>(_ content: V, size: NSSize? = nil) {
        if !Self.initializedApplication {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
            Self.initializedApplication = true
        }
        host = NSHostingView(rootView: AnyView(content))
        window = NativeTestWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size ?? host.fittingSize),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
    }

    func close() { window.close() }

    /// Coordinates use the captured image's top-left origin, in layout points.
    /// Events stay inside this test process/window; no global event posting,
    /// accessibility permission, clipboard or system pointer movement is used.
    func click(at point: NSPoint) throws {
        let location = try inputLocation(point)
        window.makeKey()
        let parentPoint = host.superview?.convert(location, from: nil) ?? location
        if let button = host.hitTest(parentPoint) as? NSButton {
            guard button.isEnabled else { throw SnapshotFailure(message: "Test button is disabled") }
            button.performClick(nil)
            return
        }
        let time = ProcessInfo.processInfo.systemUptime
        for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: time + Double(offset) * 0.05, windowNumber: window.windowNumber,
                context: nil, eventNumber: nextEventNumber, clickCount: 1, pressure: offset == 0 ? 1 : 0) else {
                throw SnapshotFailure(message: "Could not create local mouse event")
            }
            nextEventNumber += 1
            window.sendEvent(event)
        }

    }

    /// Exercise the native field editor and SwiftUI binding, without assigning
    /// the view's state directly or touching the user's clipboard.
    func replaceText(at point: NSPoint, with value: String) throws {
        let location = try inputLocation(point)
        // Split-view/scroll-view wrappers can intercept hitTest even when the
        // native field is visible. Resolve its visible rectangle in the window.
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable, field.isEnabled,
               !field.isHiddenOrHasHiddenAncestor,
               field.visibleRect.contains(field.convert(location, from: nil)) {
                return [field]
            }
            return view.subviews.flatMap { fields(in: $0) }
        }
        let candidates = fields(in: host)
        guard candidates.count == 1, let field = candidates.first else {
            throw SnapshotFailure(message: "Expected one editable native text field, found \(candidates.count)")
        }
        try replaceText(in: field, with: value)
    }

    func replaceText(placeholder: String, occurrence: Int? = nil, with value: String) throws {
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable, field.isEnabled,
               !field.isHiddenOrHasHiddenAncestor, field.placeholderString == placeholder { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        let candidates = fields(in: host)
        let index = occurrence ?? 0
        guard (occurrence != nil || candidates.count == 1), candidates.indices.contains(index) else {
            throw SnapshotFailure(message: "Expected one field for placeholder \(placeholder), found \(candidates.count)")
        }
        try replaceText(in: candidates[index], with: value)
    }

    private func replaceText(in field: NSTextField, with value: String) throws {
        window.makeKey()
        field.selectText(nil)
        guard let editor = window.firstResponder as? NSTextView else {
            throw SnapshotFailure(message: "Native field editor did not become first responder")
        }
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: editor.selectedRange())
    }

    func choosePopupItem(_ title: String) throws {
        let popup = try popup(containing: title)
        guard let menu = popup.menu else { throw SnapshotFailure(message: "Native picker has no menu") }
        menu.performActionForItem(at: popup.indexOfItem(withTitle: title))
    }

    func selectedPopupItem(containing title: String) throws -> String? {
        try popup(containing: title).titleOfSelectedItem
    }

    private func popup(containing title: String) throws -> NSPopUpButton {
        func popups(in view: NSView) -> [NSPopUpButton] {
            if let popup = view as? NSPopUpButton, popup.isEnabled,
               !popup.isHiddenOrHasHiddenAncestor, popup.itemTitles.contains(title) { return [popup] }
            return view.subviews.flatMap { popups(in: $0) }
        }
        let candidates = popups(in: host)
        guard candidates.count == 1, let popup = candidates.first else {
            throw SnapshotFailure(message: "Expected one native picker containing \(title), found \(candidates.count)")
        }
        return popup
    }

    /// Locate the rendered label independently, then activate the native control
    /// at its center. SwiftUI custom button labels do not populate NSButton.title.
    func clickButton(_ title: String) throws {
        // Segmented AppKit controls enter a blocking tracking loop on mouseDown.
        // Exercise their native target/action binding without global event queues.
        func segments(in view: NSView) -> [(NSSegmentedControl, Int)] {
            if let control = view as? NSSegmentedControl, !control.isHiddenOrHasHiddenAncestor {
                return (0..<control.segmentCount).filter { control.label(forSegment: $0) == title }.map { (control, $0) }
            }
            return view.subviews.flatMap { segments(in: $0) }
        }
        let controls = segments(in: host)
        if controls.count == 1, let (control, index) = controls.first {
            guard control.isEnabled && control.isEnabled(forSegment: index) else {
                throw SnapshotFailure(message: "Native segment is disabled")
            }
            control.selectedSegment = index
            _ = control.sendAction(control.action, to: control.target)
            return
        }
        let bitmap = try capture()
        guard let contrast = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 1,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
            bytesPerRow: bitmap.pixelsWide, bitsPerPixel: 8), let pixels = contrast.bitmapData,
            let source = bitmap.bitmapData, bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3 else {
            throw SnapshotFailure(message: "Could not prepare native button contrast")
        }
        let first = bitmap.hasAlpha && bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + first
                pixels[y * contrast.bytesPerRow + x] =
                    Int(source[offset]) + Int(source[offset + 1]) + Int(source[offset + 2]) > 384 ? 255 : 0
            }
        }
        guard let png = contrast.representation(using: .png, properties: [:]) else {
            throw SnapshotFailure(message: "Could not capture native button")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = try tesseract([file.path, "stdout", "-l", "eng", "--psm", "11", "tsv"], failure: "Button OCR failed")
        let words: [(String, NSRect)] = String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 12, columns[0] == "5", !columns[11].isEmpty,
                  let x = Double(columns[6]), let y = Double(columns[7]),
                  let w = Double(columns[8]), let h = Double(columns[9]) else { return nil }
            return (String(columns[11]).lowercased(), NSRect(x: x, y: y, width: w, height: h))
        }
        let wanted = title.lowercased().split(separator: " ").map(String.init)
        var matches: [NSRect] = []
        if words.count >= wanted.count {
            for index in 0...(words.count - wanted.count) {
                if Array(words[index..<(index + wanted.count)].map(\.0)) == wanted {
                    matches.append(words[index..<(index + wanted.count)].map(\.1).reduce(NSRect.null) { $0.union($1) })
                }
            }
        }
        let scale = host.bounds.width / CGFloat(bitmap.pixelsWide)
        if matches.count > 1 {
            matches = try matches.filter { rect in
                let location = try inputLocation(NSPoint(x: rect.midX * scale, y: rect.midY * scale))
                let parentPoint = host.superview?.convert(location, from: nil) ?? location
                return host.hitTest(parentPoint) is NSButton
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw SnapshotFailure(message: "Expected one rendered button \(title), found \(matches.count)")
        }
        try click(at: NSPoint(x: match.midX * scale, y: match.midY * scale))
    }

    private func inputLocation(_ point: NSPoint) throws -> NSPoint {
        host.layoutSubtreeIfNeeded()
        guard host.bounds.contains(point) else { throw SnapshotFailure(message: "Test input lies outside the view") }
        let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        return host.convert(local, to: nil)
    }

    private func capture() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded(); window.display()
        // OCR needs Retina-density text. Hosted CI displays are 1x, so render
        // into a 2x bitmap there; a Retina display already provides one.
        let size = host.bounds.size
        let cached = window.backingScaleFactor >= 2 ? host.bitmapImageRepForCachingDisplay(in: host.bounds)
            : NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap = cached else {
            throw SnapshotFailure(message: "Native view did not render")
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Match glyph pixels rather than OCR guesses for exact address checks. The
    /// reference is independently constructed from the expected payload, using
    /// native text rendering. No character substitutions or fuzzy match is used.
    func contains<V: View>(_ reference: V, in region: NSRect) async throws -> Bool {
        try await match(reference, in: region) != nil
    }

    func click<V: View>(_ reference: V, in region: NSRect) async throws {
        guard let point = try await match(reference, in: region) else {
            throw SnapshotFailure(message: "Expected native control pixels were not found")
        }
        try click(at: point)
    }

    private func match<V: View>(_ reference: V, in region: NSRect) async throws -> NSPoint? {
        let expected = NativeSnapshot(reference)
        defer { expected.close() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let referenceBitmap = try expected.capture()
        let actualBitmap = try capture()
        func mask(_ bitmap: NSBitmapImageRep) throws -> [Bool] {
            guard bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3, !bitmap.isPlanar,
                  let data = bitmap.bitmapData else { throw SnapshotFailure(message: "Unsupported native pixel format") }
            let first = bitmap.hasAlpha && bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
            return (0..<(bitmap.pixelsWide * bitmap.pixelsHigh)).map { pixel in
                let offset = (pixel / bitmap.pixelsWide) * bitmap.bytesPerRow + (pixel % bitmap.pixelsWide) * bitmap.samplesPerPixel + first
                return (Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])) > 384
            }
        }
        let needle = try mask(referenceBitmap), source = try mask(actualBitmap)
        let white = needle.indices.filter { needle[$0] }
        guard !white.isEmpty else { throw SnapshotFailure(message: "Empty reference text") }
        let minX = white.map { $0 % referenceBitmap.pixelsWide }.min()!
        let maxX = white.map { $0 % referenceBitmap.pixelsWide }.max()!
        let minY = white.map { $0 / referenceBitmap.pixelsWide }.min()!
        let maxY = white.map { $0 / referenceBitmap.pixelsWide }.max()!
        let width = maxX - minX + 1, height = maxY - minY + 1
        let scale = CGFloat(actualBitmap.pixelsWide) / host.bounds.width
        let left = max(0, Int(region.minX * scale)), top = max(0, Int(region.minY * scale))
        let right = min(actualBitmap.pixelsWide, Int(region.maxX * scale)) - width
        let bottom = min(actualBitmap.pixelsHigh, Int(region.maxY * scale)) - height
        guard right >= left, bottom >= top else { return nil }
        for y in top...bottom {
            for x in left...right {
                var matches = true
                rows: for row in 0..<height {
                    let needleRow = (minY + row) * referenceBitmap.pixelsWide + minX
                    let sourceRow = (y + row) * actualBitmap.pixelsWide + x
                    for column in 0..<width {
                        if needle[needleRow + column] != source[sourceRow + column] {
                            matches = false
                            break rows
                        }
                    }
                }
                if matches { return NSPoint(x: (CGFloat(x) + CGFloat(width) / 2) / scale, y: (CGFloat(y) + CGFloat(height) / 2) / scale) }
            }
        }
        return nil
    }

    func text(named name: String, in directory: URL) async throws -> String {
        // Let Observation/SwiftUI update the already-mounted hierarchy after a
        // model action, then capture real AppKit controls (not placeholder images).
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded(); window.display()
        let bitmap = try capture()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotFailure(message: "Native render could not be encoded")
        }
        let file = directory.appendingPathComponent(name + ".png")
        try png.write(to: file)
        if let path = ProcessInfo.processInfo.environment["NORTHVAULT_UI_ARTIFACTS"] {
            let artifacts = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try png.write(to: artifacts.appendingPathComponent(name + ".png"))
        }
        // Mixed light-on-dark text and dark-on-orange controls confuse automatic
        // OCR thresholding. Keep the original reads and also read an opaque mask.
        guard let contrast = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 1,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
            bytesPerRow: bitmap.pixelsWide, bitsPerPixel: 8), let pixels = contrast.bitmapData,
            bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3, !bitmap.isPlanar,
            let source = bitmap.bitmapData else {
            throw SnapshotFailure(message: "Could not prepare contrast snapshot")
        }
        let first = bitmap.hasAlpha && bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + first
                let brightness = Int(source[offset]) + Int(source[offset + 1]) + Int(source[offset + 2])
                pixels[y * contrast.bytesPerRow + x] = brightness > 192 ? 255 : 0
            }
        }
        let contrastFile = directory.appendingPathComponent(name + "-contrast.png")
        guard let contrastPNG = contrast.representation(using: .png, properties: [:]) else {
            throw SnapshotFailure(message: "Could not encode contrast snapshot")
        }
        try contrastPNG.write(to: contrastFile)
        // Dense tables and colored controls need different segmentation/contrast.
        // Privacy assertions reject a leak detected by any pass. No failed OCR
        // subprocess may silently turn into an empty (apparently private) image.
        var recognized: [String] = []
        for (input, mode) in [(file, "3"), (file, "11"), (contrastFile, "3")] {
            let text = try tesseract([input.path, "stdout", "-l", "eng", "--psm", mode],
                                     failure: "Native screen checks need Tesseract 5 with English data")
            recognized.append(String(decoding: text, as: UTF8.self).lowercased())
        }
        return recognized.joined(separator: "\n")
    }
}

private struct SnapshotFailure: Error { let message: String }

/// Runs Tesseract and returns its standard output. A failed OCR subprocess
/// must throw: it may never turn into an empty (apparently private) result.
private func tesseract(_ arguments: [String], failure: String) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [ProcessInfo.processInfo.environment["TESSERACT"] ?? "tesseract"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["OMP_THREAD_LIMIT"] = "1"
    process.environment = environment
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output; process.standardError = errors
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SnapshotFailure(message: failure + "; " +
                              String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    return bytes
}
@MainActor private final class NativeTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
#endif
