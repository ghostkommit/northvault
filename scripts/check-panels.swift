import SwiftUI

// Exercises navigation cancellation without opening windows or contacting hardware.
@main
struct PanelChecks {
    @MainActor static func main() async throws {
        let state = AppState(preview: WalletService.newSample())
        precondition(state.navigationTitle == "Total portfolio")
        var closed: [String] = []
        let reply = PassphraseReply()
        let parent = state.presentPanel("Import", onClose: { closed.append("import") }) { Text("Import") }
        let child = state.presentPanel("Passphrase", onClose: {
            closed.append("passphrase")
            reply.finish(nil)
        }) { Text("Passphrase") }
        state.showSettings()
        let settings = state.panelPages.last!
        precondition(!settings.showsHeader, "Settings must not show a separate heading or Back button")
        precondition(state.navigationTitle == "Settings", "Settings must use the window navigation title")
        let nested = state.presentPanel("Settings detail") { Text("Detail") }
        precondition(state.panelPages.last!.showsHeader, "Nested pages must retain their heading and Back navigation")
        precondition(state.navigationTitle == "Settings", "Settings details must retain the Settings window title")
        state.closePanel(nested)
        precondition(state.panelPages.last?.id == settings.id, "Back from a detail must return to Settings")
        precondition(state.panelPages.prefix(2).allSatisfy(\.showsHeader), "Other panels must retain Back navigation")
        state.closePanel(settings.id)
        precondition(state.panelPages.map(\.id) == [parent, child])
        precondition(closed.isEmpty, "Closing an unrelated page must not cancel credentials")
        state.closePanel(parent)
        precondition(closed == ["passphrase", "import"])
        precondition(reply.wait() == nil, "Leaving the parent must release the waiting device request")
        state.closePanel(parent)
        precondition(closed.count == 2, "Close callbacks must be single-use")
        precondition(state.panelPages.isEmpty)
        precondition(state.navigationTitle == "Total portfolio", "Closing Settings must restore the portfolio title")

        let account = state.accounts.first!
        state.selection = .account(account.id)
        precondition(state.navigationTitle == account.name)
        state.showSettings()
        precondition(state.navigationTitle == "Settings", "Settings must also replace an account title")
        state.closeAllPanels()
        precondition(state.navigationTitle == account.name, "Closing Settings must restore the account title")

        let standard = PassphraseReply()
        standard.finish("")
        standard.finish(nil) // onClose follows a successful user submission.
        precondition(standard.wait() == "", "Standard wallet must remain distinct from cancellation")
        try checkAddressVerificationDevices()
        checkPinEntry()
        try await checkQRSequence()
        checkQROutsideClick()
        print("Panel navigation, policy, credential cancellation, and address-verification device checks passed")
    }

    @MainActor private static func checkQROutsideClick() {
        // Exercise the same native coordinate conversion/event-consumption path
        // used by the modal monitor, with a nested card and a cancellable sequence.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 780))
        let container = NSView(frame: NSRect(x: 350, y: 100, width: 500, height: 580))
        let card = NSView(frame: container.bounds)
        root.addSubview(container)
        container.addSubview(card)
        let region = QRCodeCardRegion()
        region.view = card
        let sequence = QRCodeSequence()
        var closed = 0
        let dismiss = { closed += 1; sequence.cancel() }
        precondition(!region.dismissIfOutside(NSPoint(x: 600, y: 390), in: root, dismiss: dismiss))
        precondition(closed == 0, "Clicking the QR card must leave the modal open")
        precondition(region.dismissIfOutside(NSPoint(x: 100, y: 390), in: root, dismiss: dismiss))
        precondition(closed == 1, "An outside mouse-down must dismiss and be consumed")
        // Resizing/reflow must use current view bounds, not a cached guessed rectangle.
        container.setFrameOrigin(NSPoint(x: 100, y: 100))
        precondition(!region.dismissIfOutside(NSPoint(x: 200, y: 200), in: root, dismiss: dismiss))
        precondition(region.dismissIfOutside(NSPoint(x: 800, y: 200), in: root, dismiss: dismiss))
        card.removeFromSuperview()
        precondition(!region.dismissIfOutside(.zero, in: root, dismiss: dismiss),
                     "Do not dismiss using a detached/stale card")
        print("QR native outside-click dismissal and inside-click isolation checks passed")
    }

    @MainActor private static func checkQRSequence() async throws {
        let logo = URL(fileURLWithPath: "macos/Northvault/Resources/NorthvaultLogo.png")
        let sequence = QRCodeSequence()
        sequence.prepare(["synthetic QR frame one", "synthetic QR frame two"], logoURL: logo)
        waitForModalPreparation(sequence)
        precondition(sequence.error == nil && sequence.images.count == 2)
        let decoded = try QRImageDecoder.payloads(in: sequence.images[0])
        precondition(decoded.first == "synthetic QR frame one")
        let qrPreview = ImageRenderer(content: QRCodeOverlay(title: "Synthetic QR preview", model: sequence, dismiss: {})
            .frame(width: 1200, height: 780))
        if let image = qrPreview.cgImage {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "macos/build/qr-overlay-preview.png"))
        }
        checkModalAnimation(sequence)
        sequence.cancel()
        precondition(sequence.images.isEmpty && sequence.index == 0)
        sequence.prepare(Array(repeating: "cancelled generation", count: 60), logoURL: logo)
        sequence.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(sequence.images.isEmpty && sequence.error == nil, "Closing must discard late frames")
        sequence.prepare([], logoURL: logo)
        waitForModalPreparation(sequence)
        precondition(sequence.error == QRCodeError.empty.localizedDescription && sequence.images.isEmpty)
        sequence.prepare(["recovered QR generation"], logoURL: logo)
        waitForModalPreparation(sequence)
        precondition(sequence.images.count == 1 && sequence.error == nil, "Reopening must recover from an earlier failure")
        sequence.cancel()
        sequence.prepare(Array(repeating: "synthetic bounded QR batch", count: QRCodeRenderer.maxFrames), logoURL: logo)
        waitForModalPreparation(sequence, timeout: 30)
        precondition(sequence.error == QRCodeError.tooLarge.localizedDescription && sequence.images.isEmpty,
                     "Large exports must fail explicitly without retaining an oversized image batch")
        sequence.cancel()
        let state = AppState(preview: WalletService.newSample())
        state.isScanningDevices = true
        for width in [760, 1200] {
            let preview = ImageRenderer(content: ReceivePanel(account: state.accounts[0])
                .environment(state).frame(width: CGFloat(width), height: 780, alignment: .top)
                .background(Theme.ground).environment(\.colorScheme, .dark))
            if let image = preview.cgImage {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: "macos/build/receive-preview-\(width).png"))
            }
        }
        print("QR preparation, cancellation, and visible failure-state checks passed")
    }

    @MainActor private static func waitForModalPreparation(_ sequence: QRCodeSequence, timeout: TimeInterval = 10) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while sequence.images.isEmpty && sequence.error == nil && Date() < deadline {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.05))
        }
        precondition(!sequence.images.isEmpty || sequence.error != nil,
                     "Generation must finish while the main queue is inside the modal run loop")
    }

    @MainActor private static func checkModalAnimation(_ sequence: QRCodeSequence) {
        let initial = sequence.index
        let deadline = Date(timeIntervalSinceNow: 1)
        while sequence.index == initial && Date() < deadline {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.1))
        }
        precondition(sequence.index != initial, "QR frames must advance in the modal run-loop mode")
    }

    @MainActor private static func checkAddressVerificationDevices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try WalletService.open(dataDir: directory.path, network: .regtest, electrumUrl: nil)
        let fixtureURL = URL(fileURLWithPath: "shared/Tests/WalletStorageTests/Fixtures/descriptors-regtest.json")
        let fixtures = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        let config = try wallet.importWallet(contents: Data(fixtures["multi"]!.utf8), filename: "fixture.txt")
        // Exercise slider policies through real Swift/UniFFI descriptor creation,
        // address preview, persistence and re-export using synthetic cosigner keys.
        for total in 1...3 {
            for required in 1...total {
                var policy = MultisigPolicy()
                policy.setTotal(total)
                policy.setRequired(required)
                let candidate = WalletConfig(name: "Policy check", scriptType: policy.compatibleScriptType(.p2wpkh),
                                             threshold: UInt32(policy.required),
                                             keystores: Array(config.keystores.prefix(policy.total)))
                let preview = try wallet.previewWallet(config: candidate)
                precondition(!preview.isEmpty)
                let created = try wallet.createWallet(config: candidate)
                let data = try wallet.exportWallet(accountId: created.id, format: .descriptor)
                let imported = try wallet.importWallet(contents: data, filename: "policy.txt")
                precondition(imported.threshold == UInt32(required) && imported.keystores.count == total)
                precondition(imported.scriptType == (total == 1 ? .p2wpkh : .p2wsh))
                try wallet.deleteWallet(accountId: created.id)
            }
        }
        var bounds = MultisigPolicy()
        bounds.setTotal(100)
        bounds.setRequired(100)
        precondition(bounds == MultisigPolicy(required: 15, total: 15))
        bounds.setTotal(0)
        precondition(bounds == MultisigPolicy(required: 1, total: 1) && !bounds.isMultisig)
        bounds.setRequired(0)
        precondition(bounds.required == 1)
        // Cross the single/multisig boundary in both directions, preserving an
        // explicitly chosen script while it remains compatible with the policy.
        var transition = MultisigPolicy()
        precondition(transition.compatibleScriptType(.p2tr) == .p2tr)
        transition.setTotal(3)
        transition.setRequired(2)
        precondition(transition.isMultisig && transition.compatibleScriptType(.p2tr) == .p2wsh)
        for script in ScriptType.multisig {
            precondition(transition.compatibleScriptType(script) == script)
        }
        transition.setTotal(1)
        precondition(transition.required == 1 && transition.compatibleScriptType(.p2wsh) == .p2wpkh)
        let account = try wallet.createWallet(config: config)
        let state = AppState(preview: wallet)
        precondition(state.network == .regtest, "Preview state must retain the injected wallet's network")
        let matching = HardwareDevice(id: "trezor:matching", kind: .trezor, model: "Matching Trezor", fingerprint: config.keystores[0].fingerprint)
        let locked = HardwareDevice(id: "trezor:locked", kind: .trezor, model: "Locked Trezor", fingerprint: nil)
        let stale = HardwareDevice(id: "trezor:stale", kind: .trezor, model: "Other passphrase wallet", fingerprint: "00000000")

        state.devices = [locked]
        precondition(state.signers(for: account).isEmpty)
        precondition(state.addressVerificationDevices(for: account).map(\.id) == [locked.id],
                     "A connected, locked device must be selectable for address verification")
        state.devices = [stale, locked, matching]
        precondition(state.addressVerificationDevices(for: account).map(\.id) == [matching.id, stale.id, locked.id],
                     "Prefer matching fingerprints without excluding locked or stale discovery results")
        precondition(state.signers(for: account).map(\.id) == [matching.id],
                     "Verification selection must not change signing-device selection")
        state.devices = []
        precondition(state.addressVerificationDevices(for: account).isEmpty)

        state.selectSidebarItem(.account(account.id))
        let actions: [(String, () -> Void)] = [
            ("Wallet details", { state.showWalletDetails(account) }),
            ("Export Labels (BIP329)", { state.showAccountExport(account, format: .labels) }),
            ("Export Output descriptor", { state.showAccountExport(account, format: .descriptor) }),
            ("Import labels (BIP329)", { state.showImportLabels(account) }),
            ("Rename account", { state.showRenameAccount(account) })
        ]
        for (title, open) in actions {
            state.section = .receive
            open()
            precondition(state.navigationTitle == title)
            precondition(state.panelPages.count == 1 && !state.panelPages[0].showsHeader,
                         "Account actions must have one root panel without a Back button")
            let reply = PassphraseReply()
            var cancellations = 0
            state.presentPanel("Credential", onClose: { cancellations += 1; reply.finish(nil) }) { Text("Synthetic prompt") }
            state.selectSidebarItem(.account(account.id))
            precondition(state.panelPages.isEmpty && state.section == .transactions,
                         "Clicking the selected account must exit to Transactions")
            precondition(state.navigationTitle == account.name)
            precondition(cancellations == 1 && reply.wait() == nil,
                         "Leaving an account action must cancel pending child prompts exactly once")
            state.selectSidebarItem(.account(account.id))
            precondition(cancellations == 1)
        }
        state.showWalletDetails(account)
        let firstPanel = state.panelPages[0].id
        state.showRenameAccount(account)
        precondition(state.panelPages.count == 1 && state.panelPages[0].id != firstPanel,
                     "Switching account actions must replace the old action")
        state.selectSidebarItem(.portfolio)
        precondition(state.panelPages.isEmpty && state.navigationTitle == "Total portfolio")
        state.showAddWallet()
        precondition(state.navigationTitle == "Add account")
        precondition(state.panelPages.count == 1 && state.panelPages[0].fillsWorkspace && !state.panelPages[0].showsHeader)
        let wizard = state.panelPages[0].id
        state.presentPanel("Import key") { Text("Import") }
        state.closePanel(state.panelPages.last!.id)
        precondition(state.panelPages.last!.id == wizard, "Child workflows must preserve the full-workspace wizard")
        state.selectSidebarItem(.account(account.id))
        precondition(state.panelPages.isEmpty)
    }

    @MainActor private static func checkPinEntry() {
        let entry = PinMatrixEntry()
        precondition(!entry.finish(submit: true), "Empty PIN entry must not submit")
        // UI grid positions are encoded in Trezor's bottom-up order.
        for row in PinMatrixEntry.rows { for position in row { entry.append(position) } }
        entry.append(0)
        entry.append(10)
        entry.deleteLast()
        entry.append(3)
        precondition(entry.finish(submit: true))
        let response = PassphraseReply()
        response.finish(entry.response)
        response.finish(nil)
        precondition(response.wait() == "789456123")
        precondition(entry.positions.isEmpty && !entry.finish(submit: false))
        entry.clear()
        precondition(entry.response == nil)

        let cancelled = PinMatrixEntry()
        for _ in 0..<60 { cancelled.append(1) }
        precondition(cancelled.positions.count == 50)
        precondition(cancelled.finish(submit: false))
        cancelled.append(2)
        precondition(cancelled.response == nil && cancelled.positions.isEmpty)
        precondition(!cancelled.finish(submit: true), "Cancellation must never turn into a submission")
    }
}
