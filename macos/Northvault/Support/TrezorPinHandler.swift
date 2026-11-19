import AppKit
import SwiftUI

/// UniFFI invokes this synchronously on the dedicated hardware thread, keeping
/// the device's existing PIN request/session alive until the user responds.
final class TrezorPinHandler: TrezorPinProvider {
    private weak var state: AppState?
    init(state: AppState) { self.state = state }

    func requestPassphrase() -> String? {
        guard !Thread.isMainThread else { return nil }
        let reply = PassphraseReply()
        DispatchQueue.main.async { [weak self] in
            guard let state = self?.state else { reply.finish(nil); return }
            let id = state.presentPanel("Open your Trezor wallet", onClose: { reply.finish(nil) }) {
                TrezorPassphrasePanel(reply: reply)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                state.closePanel(id)
            }
        }
        return reply.wait()
    }

    func requestPin() -> String? {
        // Device operations must never block the main thread waiting for USB.
        guard !Thread.isMainThread else { return nil }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { Self.showMatrix() }
        }
    }

    @MainActor
    static func showMatrix(timeout: TimeInterval = 300) -> String? {
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return nil }
        let entry = PinMatrixEntry()
        let overlay = PinOverlayWindow(contentRect: parent.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.isReleasedWhenClosed = false
        overlay.title = "Unlock your Trezor"
        let finish: (Bool) -> Void = { submit in
            if entry.finish(submit: submit) { NSApp.stopModal() }
        }
        overlay.contentView = NSHostingView(rootView: PinMatrixOverlay(entry: entry, finish: finish))

        // runModal blocks other windows and commands; the full-window child catches
        // outside clicks without forwarding them to the sidebar, toolbar or content.
        parent.addChildWindow(overlay, ordered: .above)
        overlay.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === overlay else { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch event.keyCode {
                case 53: finish(false)
                case 36, 76: finish(true)
                case 51, 117: entry.deleteLast()
                case 48: return event // Keep keyboard/VoiceOver focus navigation.
                default:
                    if let text = event.characters, text.count == 1,
                       let position = Int(text), (1...9).contains(position) { entry.append(position) }
                }
            }
            return nil
        }
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: parent, queue: .main) { _ in finish(false) }
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in finish(false) }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer {
            timer.invalidate()
            NotificationCenter.default.removeObserver(observer)
            if let monitor { NSEvent.removeMonitor(monitor) }
            entry.clear()
            parent.removeChildWindow(overlay)
            overlay.orderOut(nil)
            overlay.contentView = nil
            parent.makeKey()
        }
        NSApp.runModal(for: overlay)
        return entry.response
    }

}

/// A single-use response keeps the hardware request on its original worker/session.
final class PassphraseReply {
    private let condition = NSCondition()
    private var completed = false
    private var value: String?
    func finish(_ value: String?) {
        condition.lock()
        defer { condition.unlock() }
        guard !completed else { return }
        self.value = value
        completed = true
        condition.signal()
    }
    func wait() -> String? {
        condition.lock()
        defer { value = nil; condition.unlock() }
        while !completed { condition.wait() }
        return value
    }
}

@MainActor
struct TrezorPassphrasePanel: View {
    @Environment(\.dismissPanel) private var dismiss
    let reply: PassphraseReply
    @State private var passphrase = ""
    @State private var confirmation = ""
    private var valid: Bool {
        !passphrase.isEmpty && passphrase.utf8.count <= 50 &&
            Array(passphrase.utf8) == Array(confirmation.utf8)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Choose your Trezor wallet").font(.title2)
            Text("A wallet passphrase is different from your device PIN. Choose your standard wallet below, or enter the exact passphrase for an existing wallet. A different passphrase opens a different wallet. Never enter your recovery seed.")
            Button("Use standard wallet") { finish("") }.buttonStyle(.secondary)
            Divider()
            SecureField("Existing wallet passphrase", text: $passphrase).field()
            SecureField("Confirm passphrase", text: $confirmation).field()
            if passphrase.utf8.count > 50 {
                Text("This device supports at most 50 UTF-8 bytes.").foregroundStyle(Theme.negative)
            } else if !confirmation.isEmpty && !valid {
                Text("Passphrases must match exactly.").foregroundStyle(Theme.negative)
            }
            Text("Sent only to the connected Trezor; never saved or logged. This request expires after 5 minutes.")
                .font(.caption).foregroundStyle(Theme.textMuted)
            HStack {
                Button("Cancel") { finish(nil) }.buttonStyle(.secondary)
                Button("Open passphrase wallet") { finish(passphrase) }
                    .buttonStyle(.primary).disabled(!valid)
            }
        }.padding(Theme.Space.xxl).frame(maxWidth: 700, alignment: .leading)
            .onDisappear { passphrase = ""; confirmation = "" }
    }
    private func finish(_ value: String?) {
        reply.finish(value)
        passphrase = ""
        confirmation = ""
        dismiss()
    }
}

// SECURITY-SENSITIVE: only positional codes are collected, never displayed or logged.
// Completion is one-shot; all cancellation paths discard the partial entry.
@MainActor
@Observable
final class PinMatrixEntry {
    static let rows = [[7, 8, 9], [4, 5, 6], [1, 2, 3]]
    private(set) var positions = ""
    private(set) var completed = false
    private(set) var response: String?

    func append(_ position: Int) {
        guard !completed, (1...9).contains(position), positions.count < 50 else { return }
        positions.append(String(position))
    }
    func deleteLast() {
        guard !completed, !positions.isEmpty else { return }
        positions.removeLast()
    }
    @discardableResult func finish(submit: Bool) -> Bool {
        guard !completed, !submit || !positions.isEmpty else { return false }
        response = submit ? positions : nil
        positions = ""
        completed = true
        return true
    }
    func clear() { positions = ""; response = nil }
}

private final class PinOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
struct PinMatrixOverlay: View {
    let entry: PinMatrixEntry
    let finish: (Bool) -> Void
    private let rowNames = ["Top", "Middle", "Bottom"]
    private let columnNames = ["left", "center", "right"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { finish(false) }
                .accessibilityLabel("Cancel PIN entry")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { finish(false) }
            VStack(spacing: Theme.Space.m) {
                Text("Unlock your Trezor").font(.title2.weight(.semibold))
                Text("Read the scrambled digits on your device and select their positions below.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary)
                Text(entry.positions.isEmpty ? "Enter PIN positions" : String(repeating: "•", count: entry.positions.count))
                    .font(Theme.mono(16)).frame(height: 28)
                    .accessibilityLabel("PIN positions entered")
                    .accessibilityValue("\(entry.positions.count) positions")
                VStack(spacing: 8) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<3) { column in
                                Button { entry.append(PinMatrixEntry.rows[row][column]) } label: {
                                    Text("●").font(.system(size: 22)).frame(width: 56, height: 48)
                                }
                                .buttonStyle(.secondary)
                                .accessibilityLabel("\(rowNames[row]) \(columnNames[column]) position")
                            }
                        }
                    }
                }
                HStack {
                    Button("Delete last") { entry.deleteLast() }.buttonStyle(.secondary)
                        .disabled(entry.positions.isEmpty)
                    Button("Unlock") { finish(true) }.buttonStyle(.primary)
                        .disabled(entry.positions.isEmpty)
                }
                Text("Click outside to cancel · Esc to cancel · Return to unlock\nKeyboard 1–9 selects positions, not PIN digits. Expires after 5 minutes.")
                    .font(.caption).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
            }
            .padding(Theme.Space.xxl)
            .frame(width: 400)
            .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.borderStrong))
            .contentShape(Rectangle())
            .onTapGesture {} // Consume clicks inside the entry box.
        }
        .preferredColorScheme(.dark)
    }
}
