import SwiftUI
import UniformTypeIdentifiers
import WalletModels
import WalletCrypto
import WalletStorage

extension UTType { public static let walletEnvelope = UTType(exportedAs: "org.northvault.walletenc", conformingTo: .data) }
struct EncryptedDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.walletEnvelope] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data(); _ = try WalletEnvelope.read(data) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
@MainActor public struct EncryptedWalletsView: View {
    @StateObject private var model: VaultModel
    @Environment(\.scenePhase) private var phase
    @State private var creating = false
    @State private var importing = false
    @State private var folderPicker = false
    @State private var exporting = false
    @State private var exportDocument = EncryptedDocument()
    @State private var reveal = false
    @State private var slotHex = ""
    @State private var slotIndex = "0"
    @State private var signer = 0
    @State private var pendingRemoval = false
    @State private var showSecrets = false
    private let initialDescriptor: String?
    private let initialName: String
    public init(model: VaultModel? = nil, initialDescriptor: String? = nil, name: String = "Wallet") {
        _model = StateObject(wrappedValue: model ?? VaultModel())
        self.initialDescriptor = initialDescriptor; self.initialName = name
        _creating = State(initialValue: initialDescriptor != nil)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Encrypted wallets").font(.largeTitle.bold())
            Text(model.storageLabel).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Automatic discovery locations") {
                ForEach(model.locations.directories, id: \.self) { url in
                    Text(url.path).font(.caption).textSelection(.enabled)
                }
                Text("The configured iCloud wallet folder and previously authorized shared folders are also checked.").font(.caption)
            }
            HStack {
                Menu("Settings") {
                    Button("Import descriptor") { creating = true; showSecrets = false }
                    Button("Import encrypted file") { importing = true }
                    Button("Open shared folder") { folderPicker = true }
                    Button("Refresh") { Task { await model.refresh() } }
                    Button("Saved signer secrets") { showSecrets.toggle() }
                    Button("Lock all") { model.lock(); reveal = false }
                }
                if model.busy { ProgressView().controlSize(.small) }
            }.disabled(model.busy)
            if let message = model.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            if creating { ImportDescriptorForm(model: model, isPresented: $creating, initialDescriptor: initialDescriptor, initialName: initialName) }
            else if showSecrets { secretSettings }
            else {
                ForEach(model.visible, id: \.url) { record in
                    Button { model.selected = record.url; reveal = false; pendingRemoval = false } label: {
                        HStack {
                            Image(systemName: model.unlocked[record.url] == nil ? "lock.fill" : "lock.open")
                            VStack(alignment: .leading) {
                                Text(model.unlocked[record.url]?.payload.name ?? "Locked wallet \(record.envelope.walletId.uuidString.prefix(8))")
                                Text("\(model.discovery.states[record.url]?.rawValue ?? "local") · \(model.cached.contains(record.envelope.walletId) ? "Cached key" : "Recovery required")").font(.caption).foregroundStyle(.secondary)
                            }; Spacer()
                            if model.selected == record.url { Image(systemName: "checkmark") }
                        }.padding(10)
                    }.buttonStyle(.bordered)
                }
                ForEach(model.discovery.urls.filter { url in !model.records.contains { $0.url == url } }, id: \.self) { url in
                    HStack {
                        Text("Encrypted wallet · \(model.discovery.states[url]?.rawValue ?? "waiting for download")")
                        Button("Download") { do { try model.discovery.download(url) } catch { model.message = error.localizedDescription } }
                    }
                }
                if model.records.isEmpty { Text("No encrypted wallets found yet. Northvault automatically checks its wallet folders at startup and every 15 seconds. Manual import is available in Settings.").foregroundStyle(.secondary) }
                if let record = model.current {
                    Divider()
                    if let wallet = model.unlocked[record.url] { details(wallet) } else { unlock(record) }
                    HStack {
                        Button("Export encrypted backup") { do { exportDocument = EncryptedDocument(data: try model.exportData()); exporting = true } catch { model.message = error.localizedDescription } }
                        if model.unlocked[record.url] != nil { Button("Save to primary storage") { model.publishCurrent() } }
                    }
                    let versions = model.relatedRecords(record)
                    if versions.count > 1 {
                        Text("Related copies or conflicting versions: no files or recovery slots have been deleted.").foregroundStyle(.orange)
                        ForEach(versions, id: \.url) { v in Button("Revision \(v.envelope.revision) · \(String(v.envelope.walletId.uuidString.prefix(8))) · \(String(v.envelope.revisionId.uuidString.prefix(8)))") { model.selected = v.url; reveal = false } }
                    }
                }
            }
        }.padding(24).frame(maxWidth: 850, alignment: .leading)
        .task { await model.start() }
        .onChange(of: phase) { _, p in if p == .background { model.lock(); reveal = false; slotHex = "" } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.walletEnvelope, .data], allowsMultipleSelection: false) { result in model.perform { if let url = try result.get().first { try await model.importFile(url) } } }
        .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in model.perform { if let url = try result.get().first { try await model.addFolder(url) } } }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .walletEnvelope, defaultFilename: model.current?.envelope.walletId.uuidString ?? "wallet") { if case .failure(let error) = $0 { model.message = error.localizedDescription } }
    }
    private var preferences: some View {
        VStack(alignment: .leading) {
            Toggle("Cache this wallet’s decryption key", isOn: $model.cacheDEK)
            if model.cacheDEK { Toggle("Synchronize wallet key through iCloud Keychain", isOn: $model.dekSync) }
            Toggle("Synchronize supplied BIP-85 secrets through iCloud Keychain", isOn: $model.secretSync)
            Text("Secrets are saved in Keychain, never iCloud Drive. Syncing a secret enables recovery of all wallets protected by it on your Apple Account.").font(.caption).foregroundStyle(.secondary)
            Toggle("Require device authentication before unlocking", isOn: $model.requireAuthentication)
        }
    }
    private func unlock(_ record: StoredEnvelope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unlock wallet").font(.title2)
            ForEach(record.envelope.keySlots) { s in Text("\(s.fingerprint) · \(s.bip85Path)").font(.caption.monospaced()) }
            SecureField("BIP-85 HEX; leave empty to use Keychain", text: $model.recoveryHex)
            Text("Fingerprints are hints only. Never enter a seed phrase or private signing key.").font(.caption)
            preferences
            Button("Unlock") { model.unlockCurrent() }.disabled(model.busy)
        }
    }
    private func details(_ wallet: UnlockedWallet) -> some View {
        let d = wallet.payload.descriptors
        return VStack(alignment: .leading, spacing: 12) {
            Text(wallet.payload.name).font(.title2.bold())
            Text("\(d.network.rawValue) · \(d.threshold)-of-\(d.cosigners.count) · \(d.scriptType)")
            Text("Descriptor recovery: any one authorized signer. Transaction signing policy is unchanged.").font(.caption)
            ForEach(Array(d.cosigners.enumerated()), id: \.offset) { i, c in
                Text("\(i+1). \(c.fingerprint) · \(c.origin) · \(wallet.stored.envelope.keySlots.contains { $0.cosignerIndex == i } ? "Protected" : "No recovery slot")").font(.caption.monospaced())
            }
            Button(reveal ? "Hide descriptors" : "Reveal descriptors") { reveal.toggle() }
            if reveal {
                Text(d.sourceReceive).font(.caption.monospaced()).textSelection(.enabled)
                if let change = d.sourceChange { Text(change).font(.caption.monospaced()).textSelection(.enabled) }
                Text("Validated receive").font(.caption.bold()); Text(d.receive).font(.caption.monospaced()).textSelection(.enabled)
                Text("Validated change").font(.caption.bold()); Text(d.change).font(.caption.monospaced()).textSelection(.enabled)
            }
            DisclosureGroup("Recovery and signer management") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Signer", selection: $signer) { ForEach(Array(d.cosigners.enumerated()), id: \.offset) { i,c in Text("\(i+1). \(c.fingerprint)").tag(i) } }
                    SecureField("BIP-85 HEX for a new slot", text: $slotHex)
                    TextField("BIP-85 index", text: $slotIndex)
                    Button("Add recovery slot") { let hex = slotHex; slotHex = ""; model.manageSlot(index: signer, hex: hex, bipIndex: slotIndex, remove: false, rotate: false) }
                    Button("Remove signer…") { pendingRemoval = true }
                    if pendingRemoval {
                        Text("Slot deletion does not revoke previously obtained keys. Rotation protects future revisions, but old files remain decryptable. Every retained signer’s secret must be available in Keychain; unlock using it first if necessary.").foregroundStyle(.orange)
                        Button("Remove slot only (no revocation)") { model.manageSlot(index: signer, hex: "", bipIndex: "0", remove: true, rotate: false); pendingRemoval = false }
                        Button("Remove signer and rotate key") { model.manageSlot(index: signer, hex: "", bipIndex: "0", remove: true, rotate: true); pendingRemoval = false }
                    }
                    preferences
                    Button("Save key locally") { model.saveKey(.local) }
                    Button("Save key in iCloud Keychain") { model.saveKey(.synchronized) }
                    Button("Clear local access and disable automatic unlock") { model.clearLocalAccess() }
                    Text("This device will require an explicit unlock. Shared signer secrets and synchronized keys are not deleted.").font(.caption)
                    Button("Delete device-local cached key") { model.clearKey(.local) }
                    Text("Deleting synchronized keys affects all your Apple devices. Saved signer secrets may still recover the wallet.").font(.caption)
                    Button("Delete synchronized key on all devices") { model.clearKey(.synchronized) }
                }.padding(.top,8)
            }
            Text("Keep an offline encrypted descriptor backup. A seed backup alone may not reconstruct a multisig wallet.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var secretSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Back to wallets") { showSecrets = false }
            Text("Saved BIP-85 secrets").font(.title2)
            Text("Deleting synchronized secrets affects all your Apple devices. Clearing cached wallet keys does not remove recovery secrets.").foregroundStyle(.orange)
            ForEach(Array(model.savedSecrets.enumerated()), id: \.offset) { _, entry in
                let record = entry
                let mode = entry.mode
                Text("\(record.fingerprint) · index \(record.bip85Index) · \(mode.rawValue)")
                Button(mode == .local ? "Enable iCloud Keychain sync" : "Move to this device only") { model.moveSecret(record, from: mode) }
                Button(mode == .local ? "Delete local secret" : "Delete secret on all devices") { model.deleteSecret(record, mode: mode) }
            }
        }
    }
}
private struct ImportDescriptorForm: View {
    @ObservedObject var model: VaultModel
    @Binding var isPresented: Bool
    let initialDescriptor: String?
    let initialName: String
    @State private var name = "Wallet"
    @State private var receive = ""
    @State private var change = ""
    @State private var network = WalletNetwork.mainnet
    @State private var validated: ValidatedDescriptors?
    @State private var hexes = Array(repeating: "", count: 20)
    @State private var indices = Array(repeating: "0", count: 20)
    @State private var confirmed = false
    @State private var importText = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Cancel") { hexes = Array(repeating: "", count: 20); isPresented = false }
            Text("Import and protect").font(.title2.bold())
            TextField("Wallet name", text: $name)
            Picker("Network", selection: $network) { ForEach(WalletNetwork.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Button("Read descriptor text file") { importText = true }
            Text("Receive or multipath descriptor")
            TextEditor(text: $receive).font(.caption.monospaced()).frame(height: 100)
            Text("Separate change descriptor (omit for multipath)")
            TextEditor(text: $change).font(.caption.monospaced()).frame(height: 80)
            Button("Validate descriptors") {
                do { validated = try DescriptorValidator().validate(receive: receive, change: change.isEmpty ? nil : change, network: network); model.message = nil }
                catch { validated = nil; model.message = error.localizedDescription }
            }
            if let validated {
                Text("\(validated.threshold)-of-\(validated.cosigners.count) · \(validated.scriptType)")
                ForEach(Array(validated.cosigners.enumerated()), id: \.offset) { i,c in
                    Text("Signer \(i+1): \(c.fingerprint) · \(c.origin)").font(.caption.monospaced())
                    SecureField("BIP-85 HEX (optional for this signer)", text: $hexes[i])
                    TextField("BIP-85 index", text: $indices[i])
                }
                Text("At least one recovery slot is required. Verify the HEX output on the correct signer with the correct BIP-39 passphrase. The app cannot prove that the secret belongs to a fingerprint.").font(.caption)
                Toggle("Synchronize BIP-85 secrets through iCloud Keychain", isOn: $model.secretSync)
                Toggle("Cache wallet key", isOn: $model.cacheDEK)
                if model.cacheDEK { Toggle("Synchronize wallet key through iCloud Keychain", isOn: $model.dekSync) }
                Toggle("I verified the BIP-85 path, signer and recovery backup", isOn: $confirmed)
                Button("Encrypt and save") {
                    let secrets = hexes; hexes = Array(repeating: "", count: 20)
                    model.perform { try await model.create(name: name, receive: receive, change: change, network: network, hexes: secrets, indices: indices); isPresented = false }
                }.disabled(!confirmed || !hexes.contains(where: { !$0.isEmpty }) || model.busy)
            }
        }
        .onAppear { if receive.isEmpty { receive = initialDescriptor ?? ""; name = initialName } }
        .onChange(of: receive) { _,_ in validated = nil; confirmed = false }
        .onChange(of: change) { _,_ in validated = nil; confirmed = false }
        .onChange(of: network) { _,_ in validated = nil; confirmed = false }
        .onDisappear { hexes = Array(repeating: "", count: 20) }
        .fileImporter(isPresented: $importText, allowedContentTypes: [.plainText, .data]) { result in
            do { let url = try result.get(); let scope = ScopedFolder(url: url); defer { withExtendedLifetime(scope) {} }; let text = try String(contentsOf: url, encoding: .utf8); guard text.utf8.count <= 262144 else { throw VaultError.invalid("Descriptor file too large") }; let lines = text.split(whereSeparator: \.isNewline).map(String.init); receive = lines.first ?? ""; change = lines.count == 2 ? lines[1] : ""; guard lines.count <= 2 else { throw VaultError.invalid("Expected one multipath descriptor or two descriptor lines") } }
            catch { model.message = error.localizedDescription }
        }
    }
}
