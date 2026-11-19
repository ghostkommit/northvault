import AppKit
import SwiftUI

/// Uses the same full-window, app-modal presentation as the Trezor PIN matrix.
/// No underlying account, toolbar, or other app window can act until dismissal.
@MainActor
enum QRCodePresentation {
    static func show(title: String, parts: [String]) {
        guard NSApp.modalWindow == nil,
              let parent = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let model = QRCodeSequence()
        let cardRegion = QRCodeCardRegion()
        let overlay = QRCodeOverlayWindow(contentRect: parent.frame, styleMask: .borderless,
                                          backing: .buffered, defer: false)
        overlay.title = title
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.isReleasedWhenClosed = false
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            model.cancel()
            NSApp.stopModal()
        }
        overlay.contentView = NSHostingView(rootView: QRCodeOverlay(title: title, model: model,
                                                                  dismiss: finish, cardRegion: cardRegion))
        parent.addChildWindow(overlay, ordered: .above)
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard event.window === overlay else { return event }
            if event.type == .leftMouseDown {
                guard let root = overlay.contentView else { return event }
                let point = root.convert(event.locationInWindow, from: nil)
                // Use native event delivery: SwiftUI backdrop gestures can stall
                // while the originating main-queue action is inside runModal.
                if cardRegion.dismissIfOutside(point, in: root, dismiss: finish) { return nil }
                return event
            }
            if event.keyCode == 53 { finish(); return nil }
            // Prevent account/settings/application shortcuts while the QR is open.
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return nil }
            return event
        }
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: parent, queue: .main) { _ in finish() }
        defer {
            model.cancel()
            NotificationCenter.default.removeObserver(observer)
            if let monitor { NSEvent.removeMonitor(monitor) }
            parent.removeChildWindow(overlay)
            overlay.orderOut(nil)
            overlay.contentView = nil
            parent.makeKey()
        }
        model.prepare(parts)
        NSApp.runModal(for: overlay)
    }
}

@MainActor
final class QRCodeCardRegion {
    weak var view: NSView?

    /// True means the mouse-down was consumed; it must not reach the underlying wallet.
    func dismissIfOutside(_ point: NSPoint, in root: NSView, dismiss: () -> Void) -> Bool {
        guard let view, view.isDescendant(of: root), !view.bounds.isEmpty else { return false }
        guard !view.bounds.contains(view.convert(point, from: root)) else { return false }
        dismiss()
        return true
    }
}

@MainActor @Observable
final class QRCodeSequence {
    private(set) var images: [CGImage] = []
    private(set) var index = 0
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()

    func prepare(_ parts: [String], logoURL: URL? = nil) {
        cancel()
        error = nil
        let generation = self.generation
        // A task inherited from MainActor can stall inside NSApp.runModal when
        // invoked from a main-queue action. Both work and delivery must avoid it.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<[CGImage], QRCodeError>
            do {
                try QRCodeRenderer.validate(parts)
                var images: [CGImage] = []
                var bytes = 0
                for part in parts {
                    try Task.checkCancellation()
                    let image = try QRCodeRenderer.render(part, logoURL: logoURL)
                    bytes += image.bytesPerRow * image.height
                    guard bytes <= 64 * 1024 * 1024 else { throw QRCodeError.tooLarge }
                    images.append(image)
                }
                try Task.checkCancellation()
                result = .success(images)
            } catch {
                guard !Task.isCancelled else { return }
                result = .failure((error as? QRCodeError) ?? .rendering)
            }
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    switch result {
                    case .success(let images):
                        self.images = images
                        self.startAnimation()
                    case .failure(let error): self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    private func startAnimation() {
        guard images.count > 1 else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.images.isEmpty else { return }
                self.index = (self.index + 1) % self.images.count
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    func cancel() {
        generation = UUID() // Discard completion blocks queued before cancellation.
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        images = []
        index = 0
    }
}

private final class QRCodeOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
