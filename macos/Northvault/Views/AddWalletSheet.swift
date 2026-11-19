import SwiftUI

/// Add a watch-only account: single-sig or M-of-N, keys from a USB device,
/// a file (device export) or a pasted xpub; or a whole wallet
/// file (output descriptor, multisig setup file, BSMS).
@MainActor
struct AddWalletSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismissPanel) private var dismiss

    private enum Step { case policy, keys, review }

    @State private var step: Step = .policy
    @State private var name = ""
    @State private var userNamed = false
    @State private var keyScript: ScriptType = .p2wpkh
    @State private var attemptedDevices: Set<String> = []
    @State private var scriptType: ScriptType = .p2wpkh
    @State private var policy = MultisigPolicy()
    @State private var keystores: [Keystore?] = [nil]
    @State private var error: String?

    init(policy: MultisigPolicy = MultisigPolicy()) {
        _policy = State(initialValue: policy)
        let script = policy.compatibleScriptType(.p2wpkh)
        _scriptType = State(initialValue: script)
        _keyScript = State(initialValue: script)
        _keystores = State(initialValue: Array(repeating: nil, count: policy.total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Add account").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(stepLabel).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    switch step {
                    case .policy: policyStep
                    case .keys: keysStep
                    case .review: reviewStep
                    }
                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Spacer()
                if step != .policy {
                    Button("Back") { error = nil; step = step == .review ? .keys : .policy }.buttonStyle(.secondary)
                }
                primaryButton
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            suggestName()
            if state.devices.isEmpty { await state.scanDevices() }
            if !userNamed && state.devices.count == 1 { suggestName() }
        }
    }

    private var threshold: Int { policy.required }
    private var keyCount: Int { policy.total }
    // Slider edits choose a compatible script; imported scripts remain intact,
    // including an existing 1-of-1 multisig descriptor.
    private var multisig: Bool { ScriptType.multisig.contains(scriptType) }

    private func suggestName(random: Bool = false) {
        let device = !random && state.devices.count == 1 ? state.devices.first : nil
        name = AccountDefaults.suggestedName(device: device, existing: state.accounts.map(\.name) + (random ? [name] : []))
    }

    private var stepLabel: String {
        switch step {
        case .policy: "Step 1 of 3 · Policy"
        case .keys: "Step 2 of 3 · Keys"
        case .review: "Step 3 of 3 · Review"
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .policy:
            Button("Continue") {
                let count = keyCount
                if keyScript != scriptType {
                    keystores = Array(repeating: nil, count: count)
                    attemptedDevices = []
                } else if keystores.count != count {
                    keystores = Array(keystores.prefix(count)) + Array(repeating: nil, count: max(0, count - keystores.count))
                }
                keyScript = scriptType
                error = nil
                step = .keys
            }
            .buttonStyle(.primary)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        case .keys:
            Button("Review") { error = nil; step = .review }
                .buttonStyle(.primary)
                .disabled(keystores.contains { $0 == nil })
        case .review:
            Button("Create account") { create() }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled((try? state.wallet.previewWallet(config: config)) == nil)
        }
    }

    // MARK: Step 1

    private var policyStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Name").foregroundStyle(Theme.textSecondary)
                HStack {
                    TextField("Account name", text: Binding(get: { name }, set: { name = $0; userNamed = true })).field()
                    Button { suggestName(random: true); userNamed = true } label: {
                        Image(systemName: "dice")
                    }.buttonStyle(.secondary).help("Suggest a northern-inspired name")
                }
                Text("A name for your watch-only account. You can change it later.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }

            MultisigPolicySlider(policy: Binding(get: { policy }, set: { newPolicy in
                scriptType = newPolicy.compatibleScriptType(scriptType)
                policy = newPolicy
            }))

            Picker("Script type", selection: $scriptType) {
                ForEach(multisig ? ScriptType.multisig : ScriptType.singleSig, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Default path: \(state.wallet.defaultDerivationPath(scriptType: scriptType))")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already set up in another wallet or on a Coldcard?").fontWeight(.medium)
                    Text("Import an output descriptor, a multisig setup file or a BSMS record.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("Import File…") { importWalletFile() }.buttonStyle(.secondary)
            }
        }
    }

    private func importWalletFile() {
        state.openFile(title: "Import wallet") { data, filename in
            let config = try state.wallet.importWallet(contents: data, filename: filename)
            if !userNamed || name.trimmingCharacters(in: .whitespaces).isEmpty { name = AccountDefaults.unique(config.name, existing: state.accounts.map(\.name)); userNamed = true }
            scriptType = config.scriptType
            keyScript = config.scriptType
            policy = MultisigPolicy(required: Int(config.threshold), total: config.keystores.count)
            keystores = config.keystores
            error = nil
            step = .review
        }
    }

    // MARK: Step 2

    private var keysStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(multisig ? "Add \(keystores.count) keys (\(threshold) of \(keystores.count) needed to spend)" : "Add the key")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task { await state.scanDevices() }
                } label: {
                    Label(state.isScanningDevices ? "Looking…" : "Find devices", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary)
            }
            VStack(spacing: Theme.Space.s) {
                ForEach(keystores.indices, id: \.self) { i in
                    KeystoreSlot(index: i, scriptType: scriptType, keystore: $keystores[i], error: $error,
                                 attemptedDevices: $attemptedDevices, autoRead: i == 0 && state.devices.count == 1)
                        .id("\(scriptType)-\(i)")
                }
            }
        }
    }

    // MARK: Step 3

    private var config: WalletConfig {
        WalletConfig(name: name, scriptType: scriptType, threshold: UInt32(threshold), keystores: keystores.compactMap { $0 })
    }

    private var reviewStep: some View {
        let preview = Result { try state.wallet.previewWallet(config: config) }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("\(name) · \(multisig ? "Multisig \(threshold)-of-\(keystores.count)" : "Single signature") · \(scriptType.title)")
                .fontWeight(.semibold)
            KeystoreList(keystores: config.keystores)
            switch preview {
            case .success(let lines):
                VStack(alignment: .leading, spacing: 4) {
                    Text("First receive addresses").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    ForEach(lines.dropFirst(), id: \.self) { Text($0).font(Theme.mono(12)).textSelection(.enabled) }
                }
                Label("Check these match your other wallet or your device’s address explorer before you receive funds.", systemImage: "checkmark.shield")
                    .font(.system(size: 12)).foregroundStyle(Theme.warning)
            case .failure(let e):
                Text(e.userMessage).foregroundStyle(Theme.negative)
            }
        }
    }

    private func create() {
        do {
            let account = try state.wallet.createWallet(config: config)
            state.refresh()
            state.selection = .account(account.id)
            dismiss()
            if account.isMultisig && state.devices.contains(where: { $0.kind != .trezor }) {
                state.alertMessage = "Register the wallet on your Coldcard or Jade (Account menu → Register on Device) so it can verify addresses and change."
            }
            Task { await state.sync() }
        } catch {
            self.error = error.userMessage
        }
    }
}

/// One key position: shows the key, or the ways to add it.
@MainActor
private struct KeystoreSlot: View {
    @Environment(AppState.self) private var state
    let index: Int
    let scriptType: ScriptType
    @Binding var keystore: Keystore?
    @Binding var error: String?
    @Binding var attemptedDevices: Set<String>
    let autoRead: Bool
    @State private var selectedDeviceId = ""
    @State private var readTask: Task<Void, Never>?

    @State private var manual = false
    @State private var fingerprint = ""
    @State private var path = ""
    @State private var xpub = ""
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Key \(index + 1)").fontWeight(.semibold)
                Spacer()
                if let keystore {
                    Text("\(keystore.label) · \(keystore.fingerprint) · \(keystore.derivationPath)")
                        .font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                    Button("Change") { self.keystore = nil }.buttonStyle(.secondary)
                } else if loading {
                    ProgressView().controlSize(.small)
                    Text("Confirm on the device…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                } else {
                    if !state.devices.isEmpty {
                        Picker("Device", selection: $selectedDeviceId) {
                            ForEach(state.devices) { d in Text(d.model).tag(d.id) }
                        }.labelsHidden().frame(minWidth: 180, maxWidth: .infinity)
                        Button("Read key") {
                            if let device = state.devices.first(where: { $0.id == selectedDeviceId }) { fromDevice(device) }
                        }.buttonStyle(.primary)
                    } else {
                        Text("Connect a device or import a key").font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    Button("File…") { fromFile() }.buttonStyle(.secondary)
                    Button("QR…") { fromQR() }.buttonStyle(.secondary).help("Key QR from SeedSigner, Keystone, Passport or Jade")
                    Button("xpub…") {
                        path = state.wallet.defaultDerivationPath(scriptType: scriptType)
                        manual.toggle()
                    }
                    .buttonStyle(.secondary)
                }
            }
            if keystore == nil && manual {
                HStack {
                    TextField("Fingerprint", text: $fingerprint).field().frame(minWidth: 120, maxWidth: .infinity)
                    TextField("Derivation path", text: $path).field().frame(minWidth: 170, maxWidth: .infinity)
                }
                HStack {
                    TextField("xpub / zpub / Zpub …", text: $xpub).font(Theme.mono(12)).field()
                    Button("Add") { fromText() }.buttonStyle(.primary).disabled(xpub.isEmpty || fingerprint.isEmpty)
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(keystore == nil ? Theme.borderStrong : Theme.accent))
        .task(id: state.devices.map(\.id)) {
            if !state.devices.contains(where: { $0.id == selectedDeviceId }) {
                selectedDeviceId = state.devices.first?.id ?? ""
            }
            guard autoRead, keystore == nil, let device = state.devices.first else { return }
            let attempt = "\(index):\(scriptType):\(device.id)"
            guard !attemptedDevices.contains(attempt) else { return }
            attemptedDevices.insert(attempt)
            await readDevice(device)
        }
        .onDisappear { readTask?.cancel() }
    }

    private func fromDevice(_ device: HardwareDevice) {
        guard !loading else { return }
        readTask = Task { await readDevice(device) }
    }

    private func readDevice(_ device: HardwareDevice) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let key = try await state.wallet.deviceKeystore(deviceId: device.id, scriptType: scriptType)
            guard !Task.isCancelled else { return }
            keystore = key
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.userMessage
        }
    }

    private func fromFile() {
        state.openFile(title: "Import key") { data, _ in
            keystore = try state.wallet.importKeystore(contents: data, scriptType: scriptType)
            error = nil
        }
    }

    private func fromQR() {
        state.presentPanel("Scan key") {
            QRScannerSheet(title: "Show the key QR to your camera") { decoder in
                guard let key = try state.wallet.importKeystoreQr(decoder: decoder, scriptType: scriptType) else { return false }
                keystore = key
                error = nil
                return true
            }
        }
    }

    private func fromText() {
        let trimmedPath = path.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "m/", with: "")
        let expression = "[\(fingerprint.trimmingCharacters(in: .whitespaces))/\(trimmedPath)]\(xpub.trimmingCharacters(in: .whitespaces))"
        do {
            var key = try state.wallet.importKeystore(contents: Data(expression.utf8), scriptType: scriptType)
            key.label = "Key \(index + 1)"
            keystore = key
            manual = false
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }
}
