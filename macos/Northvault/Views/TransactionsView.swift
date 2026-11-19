import SwiftUI

@MainActor
struct TransactionsView: View {
    @Environment(AppState.self) private var state
    let account: Account

    var body: some View {
        let money = state.money
        let needsSync = state.historyNeedsSync(accountId: account.id)
        let price = state.btcPriceUSD
        let txs = state.wallet.transactions(accountId: account.id)
        let utxos = state.wallet.utxos(accountId: account.id)
        let pending = txs.filter(\.isPending)
        let pendingSats = pending.reduce(Int64(0)) { $0 + $1.amountSats }
        let confirmedSats = Int64(account.balanceSats) - max(pendingSats, 0)

        ScrollView {
        VStack(spacing: Theme.Space.xl) {
            NetWorthCard(accountId: account.id, title: account.name)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                StatTile(label: "Confirmed balance", value: needsSync ? "—" : money.bitcoin(confirmedSats),
                         detail: needsSync ? "Sync required" : money.currency == .btc ? account.standard : money.value(sats: confirmedSats, priceUSD: price))
                StatTile(label: "Unconfirmed", value: needsSync ? "—" : money.bitcoin(pendingSats, signed: !pending.isEmpty),
                         detail: needsSync ? "Sync required" : pending.isEmpty ? "Nothing pending" : "\(pending.count) pending")
                StatTile(label: "Transactions", value: needsSync ? "—" : "\(txs.count)",
                         detail: txs.last.map { "Since \(Date(unix: $0.timestamp).formatted(date: .abbreviated, time: .omitted))" } ?? "")
                StatTile(label: "Unspent outputs", value: needsSync ? "—" : "\(utxos.count)",
                         detail: needsSync ? "Sync required" : "Largest \(money.bitcoin(utxos.map(\.valueSats).max() ?? 0))")
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Transactions").font(.system(size: 15, weight: .semibold))
                    Text(needsSync ? "Not downloaded" : "\(txs.count) total").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("Export CSV") { exportCSV(txs) }.buttonStyle(.secondary).disabled(txs.isEmpty)
                }
                .padding(Theme.Space.l)

                Table(txs) {
                    TableColumn("Date") { tx in
                        Text(Date(unix: tx.timestamp), format: .dateTime.month(.abbreviated).day().year())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .width(min: 100, ideal: 110)

                    TableColumn("Label") { tx in
                        HStack(spacing: 10) {
                            DirectionBadge(incoming: tx.isIncoming)
                            Text(tx.label ?? "—").lineLimit(1)
                        }
                        .labelEditor(account: account, kind: .transaction, reference: tx.txid, current: tx.label)
                    }
                    .width(min: 160, ideal: 220)

                    TableColumn("Transaction ID") { tx in
                        Text(tx.txid.abbreviated(head: 8, tail: 8))
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textMuted)
                            .textSelection(.enabled)
                            .help(tx.txid)
                    }
                    .width(min: 150, ideal: 170)

                    TableColumn("Value") { tx in
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(money.bitcoin(tx.amountSats, signed: true))
                                .font(Theme.mono(13))
                                .foregroundStyle(tx.isIncoming ? Theme.incoming : Theme.text)
                            let fiat = money.fiatSubtitle(sats: tx.amountSats, priceUSD: price, signed: true)
                            if !fiat.isEmpty {
                                Text(fiat).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 160, ideal: 190)

                    TableColumn("Balance") { tx in
                        Text(money.bitcoin(tx.balanceAfterSats))
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 150, ideal: 170)

                    TableColumn("Status") { tx in
                        StatusPill(pending: tx.isPending)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 96, ideal: 110)
                }
                .walletTable()
                .frame(height: 520) // scrolls inside; the page scrolls around it
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: 1240)
        }
    }

    private func exportCSV(_ txs: [WalletTransaction]) {
        let quote: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        var csv = "Date,Label,Value (sats),Balance (sats),Txid,Confirmations\n"
        for tx in txs {
            csv += [iso.string(from: Date(unix: tx.timestamp)), quote(tx.label ?? ""), "\(tx.amountSats)", "\(tx.balanceAfterSats)", tx.txid, "\(tx.confirmations)"]
                .joined(separator: ",") + "\n"
        }
        state.saveFile(Data(csv.utf8), suggestedName: "\(account.name) transactions.csv")
    }
}
