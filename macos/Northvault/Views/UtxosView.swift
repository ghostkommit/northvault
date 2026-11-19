import SwiftUI

struct UtxosView: View {
    @Environment(AppState.self) private var state
    let account: Account

    var body: some View {
        @Bindable var state = state
        let money = state.money
        let price = state.btcPriceUSD
        let utxos = state.wallet.utxos(accountId: account.id)
        let selected = utxos.filter { state.selectedUtxoIDs.contains($0.id) }
        let selectedSats = selected.reduce(UInt64(0)) { $0 + $1.valueSats }
        let allSelected = !utxos.isEmpty && selected.count == utxos.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text("Unspent outputs").font(.system(size: 15, weight: .semibold))
                Text(selected.isEmpty
                     ? "\(utxos.count) outputs · \(money.bitcoin(account.balanceSats))"
                     : "\(selected.count) of \(utxos.count) selected · \(money.bitcoin(selectedSats))")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button(allSelected ? "Clear selection" : "Select all") {
                    let ids = Set(utxos.map(\.id))
                    if allSelected { state.selectedUtxoIDs.subtract(ids) } else { state.selectedUtxoIDs.formUnion(ids) }
                }
                .buttonStyle(.secondary)

                Button("Send selected") {
                    // Coin control: SendView spends exactly the selected outputs.
                    state.section = .send
                }
                .buttonStyle(.primary)
                .disabled(selected.isEmpty)
            }
            .padding(Theme.Space.l)

            CompositionBar(utxos: utxos, total: account.balanceSats, selected: state.selectedUtxoIDs)
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.l)

            // Native multi-select (click, ⌘-click, ⇧-click) replaces checkboxes.
            Table(utxos, selection: $state.selectedUtxoIDs) {
                TableColumn("Date") { u in
                    Text(Date(unix: u.timestamp), format: .dateTime.month(.abbreviated).day().year())
                        .foregroundStyle(Theme.textSecondary)
                }
                .width(min: 100, ideal: 110)

                TableColumn("Output") { u in
                    Text("\(u.txid.abbreviated(head: 10, tail: 6)):\(u.vout)")
                        .font(Theme.mono(12)).foregroundStyle(Theme.textMuted).help(u.txid)
                }

                TableColumn("Address") { u in
                    Text(u.address.abbreviated(head: 12, tail: 8)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                }

                TableColumn("Label") { u in
                    Text(u.label ?? "—").foregroundStyle(Theme.textSecondary).lineLimit(1)
                        .labelEditor(account: account, kind: .output, reference: u.id, current: u.label)
                }

                TableColumn("Value") { u in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(money.bitcoin(u.valueSats)).font(Theme.mono(13))
                        let fiat = money.fiatSubtitle(sats: Int64(u.valueSats), priceUSD: price)
                        if !fiat.isEmpty { Text(fiat).font(.system(size: 11)).foregroundStyle(Theme.textMuted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 150, ideal: 180)
            }
            .walletTable()
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .padding(Theme.Space.xxl)
    }
}

/// Horizontal bar showing each UTXO's share of the balance.
private struct CompositionBar: View {
    let utxos: [Utxo]
    let total: UInt64
    let selected: Set<Utxo.ID>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(utxos.enumerated()), id: \.element.id) { i, u in
                        Rectangle()
                            .fill(selected.contains(u.id) ? Theme.accent : (i.isMultiple(of: 2) ? Theme.borderStrong : Color(hex: 0x343C47)))
                            .frame(width: max(2, geo.size.width * CGFloat(u.valueSats) / CGFloat(max(total, 1)) - 2))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)

            Text("Composition by value · selected outputs highlighted")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
    }
}
