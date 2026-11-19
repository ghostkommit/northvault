import SwiftUI

struct AddressesView: View {
    @Environment(AppState.self) private var state
    let account: Account
    @State private var chain: Chain = .receive

    var body: some View {
        let money = state.money
        let rows = (try? state.wallet.addresses(accountId: account.id, chain: chain)) ?? []
        let nextUnused = chain == .receive ? rows.first(where: { $0.txCount == 0 })?.index : nil
        let used = rows.filter { $0.txCount > 0 }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Text("Addresses").font(.system(size: 15, weight: .semibold))
                Picker("Chain", selection: $chain) {
                    Text("Receive").tag(Chain.receive)
                    Text("Change").tag(Chain.change)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(used) used · \(account.derivationPath)/\(chain == .receive ? 0 : 1)/*")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            .padding(Theme.Space.l)

            Table(rows) {
                TableColumn("Path") { a in
                    Text("/\(a.chain == .receive ? 0 : 1)/\(a.index)").font(Theme.mono(12)).foregroundStyle(Theme.textMuted)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Address") { a in
                    HStack(spacing: 8) {
                        Text(a.address)
                            .font(Theme.mono(12))
                            .foregroundStyle(a.txCount > 0 ? Theme.text : Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if a.index == nextUnused {
                            Text("Next")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                }
                .width(min: 260, ideal: 420)

                TableColumn("Label") { a in
                    Text(a.label ?? "—").foregroundStyle(Theme.textSecondary).lineLimit(1)
                        .labelEditor(account: account, kind: .address, reference: a.address, current: a.label)
                }

                TableColumn("Txs") { a in
                    Text(a.txCount > 0 ? "\(a.txCount)" : "—")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(50)

                TableColumn("Balance") { a in
                    Text(a.txCount > 0 ? money.bitcoin(a.balanceSats) : "Unused")
                        .font(Theme.mono(12))
                        .foregroundStyle(a.balanceSats > 0 ? Theme.text : Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 140, ideal: 170)
            }
            .walletTable()
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .padding(Theme.Space.xxl)
    }
}
