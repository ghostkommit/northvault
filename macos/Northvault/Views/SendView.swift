import SwiftUI

// SECURITY-SENSITIVE — requires human review before merge.
// Spending UI: recipient, amount, fee and coin control. Builds an unsigned
// PSBT in Rust; signing happens on the hardware device (SignTransactionSheet).
@MainActor
struct SendView: View {
    @Environment(AppState.self) private var state
    let account: Account

    @State private var payTo = ""
    @State private var label = ""
    @State private var amountText = ""
    @State private var sendMax = false
    @State private var feeLevel: FeeLevel = .standard
    @State private var customRate = ""

    var body: some View {
        let money = state.money
        let price = state.btcPriceUSD
        let fees = state.wallet.feeEstimates()
        let rate = fees.first { $0.level == feeLevel }?.satPerVb ?? Double(customRate) ?? 0
        let amountSats = state.unit.parse(amountText)
        let coins = selectedCoins
        let draft = Result { try state.wallet.draftTransaction(accountId: account.id, address: payTo, amountSats: amountSats, satPerVb: rate, selectedUtxos: coins.map(\.outPoint), sendMax: sendMax) }
        let error = draftError(draft)

        ScrollView {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                // Form
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text("Send from \(account.name)").font(.system(size: 16, weight: .semibold))

                    LabeledField("Pay to") {
                        TextField(placeholder, text: $payTo)
                            .font(Theme.mono(13))
                            .field(invalid: error == .InvalidAddress || error == .WrongNetwork)
                    }

                    LabeledField("Label", hint: "Only stored in this wallet") {
                        TextField("e.g. Invoice from contractor", text: $label).field()
                    }

                    LabeledField("Amount") {
                        HStack(spacing: Theme.Space.s) {
                            HStack {
                                TextField(state.unit == .btc ? "0.00000000" : "0", text: $amountText)
                                    .font(Theme.mono(15))
                                    .textFieldStyle(.plain)
                                    .disabled(sendMax)
                                Text(state.unit.rawValue).foregroundStyle(Theme.textMuted)
                            }
                            .field(invalid: isFundsError(error))

                            Toggle("Max", isOn: $sendMax)
                                .toggleStyle(.button)
                                .onChange(of: sendMax) { _, on in
                                    if on, let d = try? draft.get() { amountText = state.unit.inputString(d.amountSats) }
                                }
                        }
                        Text(amountSats > 0 ? "≈ \(money.value(sats: Int64(amountSats), priceUSD: price))" : " ")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Network fee").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        if fees.isEmpty {
                            HStack {
                                TextField("sat/vB", text: $customRate).font(Theme.mono(13)).field().frame(width: 120)
                                Text("Fee estimates appear after syncing with your server.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                            }
                        } else {
                            HStack(spacing: Theme.Space.m) {
                                ForEach(fees, id: \.level) { fee in
                                    FeeOption(fee: fee, selected: fee.level == feeLevel) { feeLevel = fee.level }
                                }
                            }
                        }
                    }

                    if !coins.isEmpty {
                        HStack {
                            Label("Spending \(coins.count) selected coin\(coins.count == 1 ? "" : "s") (\(money.bitcoin(coins.reduce(0) { $0 + $1.valueSats })))", systemImage: "circle.grid.2x2")
                                .font(.system(size: 13)).foregroundStyle(Theme.accent)
                            Spacer()
                            Button("Use any coins") { state.selectedUtxoIDs.subtract(coins.map(\.id)) }.buttonStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 22)

                // Summary
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Summary").font(.system(size: 16, weight: .semibold))
                    let d = try? draft.get()
                    SummaryRow(label: "Amount", value: d.map { money.bitcoin($0.amountSats) }, detail: d.map { money.fiatSubtitle(sats: Int64($0.amountSats), priceUSD: price) })
                    SummaryRow(label: "Network fee", value: d.map { money.bitcoin($0.feeSats) }, detail: d.map { String(format: "%.1f sat/vB × %d vB", $0.effectiveFeeRate, $0.vbytes) })
                    SummaryRow(label: "Total", value: d.map { money.bitcoin($0.totalSats) }, detail: d.map { money.fiatSubtitle(sats: Int64($0.totalSats), priceUSD: price) })
                    SummaryRow(label: "Balance after", value: d.map { money.bitcoin($0.balanceAfterSats) }, detail: nil)

                    ForEach(d?.warnings ?? [], id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warning)
                    }

                    if let error, !payTo.isEmpty || amountSats > 0 || sendMax {
                        Text(error.message).font(.system(size: 13)).foregroundStyle(Theme.negative)
                    }

                    Button("Create transaction") { create() }
                        .buttonStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .disabled(d == nil || state.isSample)

                    Text(state.isSample
                         ? "The sample wallet can’t create transactions."
                         : "You’ll review and sign it on your hardware device before it is broadcast.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(width: 340, alignment: .leading)
                .card(padding: 22)
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 1240)
        }
    }

    private var placeholder: String {
        state.network == .bitcoin ? "bc1q… or bc1p… address" : "tb1… / bcrt1… address"
    }

    /// UTXOs selected on the UTXO tab for this account (coin control).
    private var selectedCoins: [Utxo] {
        state.wallet.utxos(accountId: account.id).filter { state.selectedUtxoIDs.contains($0.id) }
    }

    private func create() {
        let fees = state.wallet.feeEstimates()
        let rate = fees.first { $0.level == feeLevel }?.satPerVb ?? Double(customRate) ?? 0
        let coins = selectedCoins
        let draft = state.attempt {
            try state.wallet.createTransaction(accountId: account.id, address: payTo, amountSats: state.unit.parse(amountText),
                                               satPerVb: rate, selectedUtxos: selectedCoins.map(\.outPoint), sendMax: sendMax)
        }
        if let draft {
            state.presentPanel("Review and sign") {
                SignTransactionSheet(account: account, draft: draft, label: label) {
                    payTo = ""; label = ""; amountText = ""; sendMax = false
                    state.selectedUtxoIDs.subtract(coins.map(\.id))
                }
            }
        }
    }

    private func draftError(_ result: Result<DraftTransaction, Error>) -> WalletError? {
        if case .failure(let e) = result { return e as? WalletError }
        return nil
    }

    private func isFundsError(_ e: WalletError?) -> Bool {
        if case .InsufficientFunds? = e { return true }
        return false
    }
}

extension DraftTransaction: Identifiable {
    public var id: String { psbtBase64 }
}

private struct LabeledField<Content: View>: View {
    let title: String
    var hint: String?
    let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(Theme.textSecondary)
                if let hint { Text("(\(hint))").foregroundStyle(Theme.textMuted) }
            }
            .font(.system(size: 13))
            content
        }
    }
}

private struct FeeOption: View {
    let fee: FeeEstimate
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fee.level.title).fontWeight(.semibold)
                Text("\(Int(fee.satPerVb)) sat/vB").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(fee.etaText).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .background(selected ? Theme.surfaceRaised : Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(selected ? Theme.accent : Theme.borderStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String?
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value ?? "—").font(Theme.mono(13))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(.bottom, Theme.Space.m)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
