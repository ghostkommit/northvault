import SwiftUI

// SECURITY-SENSITIVE — requires human review before merge.
// Collects signatures from hardware devices (USB, SD card file, animated QR)
// until the policy is met, then broadcasts after a final confirmation. Every
// signed PSBT is checked in Rust against the transaction created here.
@MainActor
struct SignTransactionSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismissPanel) private var dismiss
    let account: Account
    let draft: DraftTransaction
    let label: String
    let onBroadcast: () -> Void

    @State private var signed: [String] = []
    @State private var status: SignatureStatus?
    @State private var busyDevice: String?
    @State private var broadcasting = false
    @State private var txid: String?
    @State private var error: String?

    var body: some View {
        let money = state.money
        let keystores = (try? state.wallet.walletDetails(accountId: account.id).keystores) ?? []
        let have = status?.signatures ?? 0
        let need = status?.required ?? (account.isMultisig ? 2 : 1)

        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(txid == nil ? "Review and sign" : "Transaction sent").font(.system(size: 18, weight: .semibold))

            if let txid {
                Label("Broadcast to the network.", systemImage: "checkmark.circle").foregroundStyle(Theme.positive)
                InfoTile(label: "Transaction ID", value: txid, mono: true)
                HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
            } else {
                // What the device should show. Compare before approving.
                VStack(spacing: Theme.Space.s) {
                    ForEach(Array(draft.outputs.enumerated()), id: \.offset) { _, out in
                        HStack(alignment: .firstTextBaseline) {
                            Text(out.address).font(Theme.mono(12)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            if out.isChange { StatusLabel(text: "Change") }
                            Spacer()
                            Text(money.bitcoin(out.amountSats)).font(Theme.mono(13))
                        }
                    }
                    HStack {
                        Text("Network fee").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(money.bitcoin(draft.feeSats)) · \(String(format: "%.1f", draft.effectiveFeeRate)) sat/vB").font(Theme.mono(13))
                    }
                }
                .card(padding: Theme.Space.l)

                ForEach(draft.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warning)
                }

                HStack {
                    Text("Signatures").fontWeight(.semibold)
                    Text("\(have) of \(need)").font(Theme.mono(13)).foregroundStyle(have >= need ? Theme.positive : Theme.textSecondary)
                }
                HStack(spacing: Theme.Space.s) {
                    ForEach(keystores, id: \.fingerprint) { k in
                        let done = status?.signedBy.contains(k.fingerprint) ?? false
                        Label("\(k.label) · \(k.fingerprint)", systemImage: done ? "checkmark.seal.fill" : "seal")
                            .font(.system(size: 12))
                            .foregroundStyle(done ? Theme.positive : Theme.textMuted)
                    }
                }

                if have < need { signingOptions }

                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                    Spacer()
                    if broadcasting { ProgressView().controlSize(.small) }
                    Button("Broadcast…") {
                        state.confirm("Broadcast this transaction?",
                            message: "Sends \(money.bitcoin(draft.amountSats)) plus a \(money.bitcoin(draft.feeSats)) fee. This can’t be undone.",
                            actionTitle: "Broadcast") { broadcast() }
                    }
                        .buttonStyle(.primary)
                        .disabled(have < need || broadcasting)
                }
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Theme.ground)
        .task { refreshStatus() }
    }

    private var signingOptions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Text("USB").font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(width: 70, alignment: .leading)
                let signers = state.signers(for: account)
                if signers.isEmpty {
                    Text("No signing device connected").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                ForEach(signers) { device in
                    Button {
                        sign(with: device)
                    } label: {
                        Label(busyDevice == device.id ? "Confirm on \(device.model)…" : "Sign with \(device.model)", systemImage: "cable.connector")
                    }
                    .buttonStyle(.secondary)
                    .disabled(busyDevice != nil)
                }
                Spacer()
                Button { Task { await state.scanDevices() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.secondary)
                    .help("Look for devices")
            }
            HStack(spacing: Theme.Space.s) {
                Text("Air-gapped").font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(width: 70, alignment: .leading)
                Button("Save PSBT…") { savePsbt() }.buttonStyle(.secondary).help("For Coldcard (SD card) or another wallet")
                Button("Show QR") {
                    if let parts = state.attempt({ try state.wallet.psbtToUrParts(psbt: draft.psbtBase64) }) {
                        QRCodePresentation.show(title: "Scan with your signing device", parts: parts)
                    }
                }
                    .buttonStyle(.secondary).help("Animated BC-UR QR for Jade, Keystone, Passport")
                Button("Load Signed PSBT…") { loadPsbt() }.buttonStyle(.secondary)
                Button("Scan QR…") {
                    state.presentPanel("Scan signed transaction") {
                        QRScannerSheet(title: "Show the signed transaction QR to your camera") { decoder in
                            guard let psbt = try decoder.result() else { return false }
                            add(signedPsbt: psbt)
                            return true
                        }
                    }
                }.buttonStyle(.secondary)
            }
        }
        .card(padding: Theme.Space.l)
    }

    private func refreshStatus() {
        status = try? state.wallet.signatureStatus(accountId: account.id, draftPsbt: draft.psbtBase64, signedPsbts: signed)
    }

    /// Accepts a signed PSBT only if it is for this exact transaction.
    private func add(signedPsbt: String) {
        do {
            status = try state.wallet.signatureStatus(accountId: account.id, draftPsbt: draft.psbtBase64, signedPsbts: signed + [signedPsbt])
            signed.append(signedPsbt)
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }

    private func sign(with device: HardwareDevice) {
        busyDevice = device.id
        Task { @MainActor in
            defer { busyDevice = nil }
            do {
                add(signedPsbt: try await state.wallet.deviceSign(deviceId: device.id, accountId: account.id, psbt: draft.psbtBase64))
            } catch {
                self.error = error.userMessage
            }
        }
    }

    private func savePsbt() {
        do {
            let data = try state.wallet.psbtToFile(psbt: draft.psbtBase64)
            state.saveFile(data, suggestedName: "\(account.name) unsigned.psbt")
        } catch {
            self.error = error.userMessage
        }
    }

    private func loadPsbt() {
        state.openFile(title: "Load signed PSBT") { data, _ in
            let psbt = try state.wallet.psbtFromFile(contents: data)
            // Validate before dismissing the import page so failures remain visible.
            let updated = try state.wallet.signatureStatus(accountId: account.id, draftPsbt: draft.psbtBase64, signedPsbts: signed + [psbt])
            signed.append(psbt)
            status = updated
            error = nil
        }
    }

    private func broadcast() {
        broadcasting = true
        Task { @MainActor in
            defer { broadcasting = false }
            do {
                let id = try await state.wallet.broadcast(accountId: account.id, draftPsbt: draft.psbtBase64, signedPsbts: signed)
                if !label.trimmingCharacters(in: .whitespaces).isEmpty {
                    try? state.wallet.setLabel(accountId: account.id, kind: .transaction, reference: id, label: label)
                }
                txid = id
                onBroadcast()
                state.refresh()
            } catch {
                self.error = error.userMessage
            }
        }
    }
}

private struct StatusLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.surfaceRaised, in: Capsule())
    }
}
