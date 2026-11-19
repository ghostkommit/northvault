import SwiftUI
import AppKit

// SECURITY-SENSITIVE — requires human review before merge (address generation and verification).
struct ReceiveView: View {
    let account: Account

    var body: some View {
        ScrollView { ReceivePanel(account: account) }
    }
}

// Kept separate from the native scroll view so the actual panel can be rendered
// in isolated layout checks without opening a wallet window.
struct ReceivePanel: View {
    @Environment(AppState.self) private var state
    let account: Account
    @State private var label = ""
    @State private var verifying: String?
    @State private var verifiedAddresses: [String: String] = [:]

    var body: some View {
        let offset = state.receiveOffsets[account.id] ?? 0
        let info = try? state.wallet.nextReceiveAddress(accountId: account.id, offset: offset)
        let lastReceived = state.wallet.transactions(accountId: account.id).first(where: \.isIncoming)

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Receive to \(account.name)").font(.system(size: 16, weight: .semibold))
                Text("Address #\(info?.index ?? 0) · \(info?.derivationPath ?? "")")
                    .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            }

            ReceiveAddressBar(address: info?.address) {
                state.receiveOffsets[account.id] = offset + 1
                label = ""
            }

            Button {
                guard let address = info?.address else { return }
                QRCodePresentation.show(title: "Receive to \(account.name)", parts: ["bitcoin:\(address)"])
            } label: {
                Label("Show QR code", systemImage: "qrcode")
            }
            .buttonStyle(.secondary)
            .disabled(info == nil)

            verificationButtons(info)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Label").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                TextField(info?.label ?? "Who is paying you?", text: $label)
                    .field()
                    .onSubmit {
                        guard let address = info?.address, !state.isSample else { return }
                        state.attempt { try state.wallet.setLabel(accountId: account.id, kind: .address, reference: address, label: label) }
                        state.refresh()
                    }
            }

            HStack(spacing: Theme.Space.s) {
                InfoTile(label: "Script type", value: account.scriptType.label)
                InfoTile(label: "Policy", value: account.policy)
                InfoTile(label: "Last received",
                         value: lastReceived.map { Date(unix: $0.timestamp).formatted(date: .abbreviated, time: .omitted) } ?? "Never")
            }

            Label("Always confirm the address on your hardware device before sharing it.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.warning)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warningBg, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Space.xxl)
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

extension ReceivePanel {
    @ViewBuilder fileprivate func verificationButtons(_ info: AddressInfo?) -> some View {
        let devices = state.addressVerificationDevices(for: account)
        if devices.isEmpty {
            Button {
                Task { await state.scanDevices() }
            } label: {
                Label("Find devices", systemImage: "cable.connector")
            }
            .buttonStyle(.secondary)
            .disabled(state.isScanningDevices)
        } else {
            DeviceButtonFlow {
                deviceButtons(devices, info: info)
            }
        }
    }

    @ViewBuilder fileprivate func deviceButtons(_ devices: [HardwareDevice], info: AddressInfo?) -> some View {
        ForEach(devices) { device in
            let isVerified = info.map { verifiedAddresses[device.id] == $0.address } ?? false
            Button { verify(info, on: device) } label: {
                Label(verifying == device.id ? "Confirm on \(device.model)…" :
                        (isVerified ? "Verified on \(device.model)" : "Verify on \(device.model)"),
                      systemImage: isVerified ? "checkmark.shield.fill" : "checkmark.shield")
                    .fixedSize()
            }
            .buttonStyle(.secondary)
            .disabled(state.isSample || info == nil || verifying != nil)
        }
    }

    /// The device derives the address itself; Rust compares it with ours.
    fileprivate func verify(_ info: AddressInfo?, on device: HardwareDevice) {
        guard let info else { return }
        verifying = device.id
        Task { @MainActor in
            defer { verifying = nil }
            do {
                verifiedAddresses[device.id] = try await state.wallet.deviceVerifyAddress(deviceId: device.id, accountId: account.id, chain: .receive, index: info.index)
            } catch {
                verifiedAddresses[device.id] = nil
                state.alertMessage = error.userMessage
            }
        }
    }
}

private struct DeviceButtonFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (view, origin) in zip(subviews, arrangement.origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                       anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + Theme.Space.s
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + Theme.Space.s
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}

struct ReceiveAddressBar: View {
    let address: String?
    let nextAddress: () -> Void
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            addressRow(compact: false)
            addressRow(compact: true)
        }
        .onChange(of: address) { _, _ in copied = false }
        .onDisappear { if hovering { NSCursor.arrow.set() } }
    }

    private func addressRow(compact: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                guard let address else { return }
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(address, forType: .string)
            } label: {
                Text(address?.grouped ?? "Address unavailable")
                    .font(Theme.mono(16))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(Theme.Space.l)
                    .padding(.trailing, Theme.Space.m)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.borderStrong))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(copied ? Theme.positive : Theme.textMuted)
                            .padding(Theme.Space.s)
                            .opacity(hovering || copied ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 220, maxWidth: .infinity)
            .disabled(address == nil)
            .help(copied ? "Copied" : "Click to copy address")
            .accessibilityLabel("Copy receive address")
            .accessibilityValue(copied ? "Copied" : (address ?? "Unavailable"))
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hovering = address != nil
                    if hovering { NSCursor.dragCopy.set() }
                case .ended:
                    hovering = false
                    NSCursor.arrow.set()
                }
            }

            Button(action: nextAddress) {
                Group {
                    if compact {
                        Image(systemName: "arrow.clockwise")
                    } else {
                        Label("Next address", systemImage: "arrow.clockwise")
                    }
                }
                .fixedSize()
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.secondary)
            .disabled(address == nil)
            .help("Next address")
            .accessibilityLabel("Next address")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
