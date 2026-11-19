import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let money = state.money
        let price = state.btcPriceUSD
        let total = Int64(state.wallet.totalBalanceSats())

        VStack(spacing: 0) {
            // Keep the first row outside List's automatic sidebar header inset.
            Button { state.selectSidebarItem(.portfolio) } label: {
                TotalPortfolioRow(
                    value: state.historyNeedsSync() ? "Not synced" : (money.currency == .btc ? money.bitcoin(total) : money.value(sats: total, priceUSD: price)),
                    detail: state.historyNeedsSync() ? "Balance unavailable" : (money.currency == .btc ? "\(state.accounts.count) accounts" : money.bitcoin(total))
                )
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(sidebarHighlight(selected: state.selection == .portfolio))
            .accessibilityAddTraits(state.selection == .portfolio ? .isSelected : [])

            List(selection: Binding(get: { state.selection }, set: { state.selectSidebarItem($0) })) {
                Section("Accounts") {
                    ForEach(state.accounts) { account in
                        AccountRow(account: account, money: money, priceUSD: price, needsSync: state.historyNeedsSync(accountId: account.id))
                            .tag(SidebarItem.account(account.id))
                            .listItemTint(.fixed(Theme.accent))
                            .listRowBackground(sidebarHighlight(selected: state.selection == .account(account.id)))
                            .contentShape(Rectangle())
                            .onTapGesture { state.selectSidebarItem(.account(account.id)) }
                            .accessibilityAction { state.selectSidebarItem(.account(account.id)) }
                    }
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.sidebar)
        .tint(Theme.accent)
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
                .padding(Theme.Space.m)
                .background(Theme.sidebar)
        }
    }

    private func sidebarHighlight(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .fill(selected ? Theme.sidebarSelection : Theme.sidebar)
            .padding(.horizontal, 10)
    }
}

private struct TotalPortfolioRow: View {
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Eyebrow(text: "Total portfolio")
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRow: View {
    let account: Account
    let money: MoneyFormat
    let priceUSD: Double
    let needsSync: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: account.isMultisig ? "lock.shield" : "key")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(account.policy).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(needsSync ? "Not synced" : money.bitcoin(account.balanceSats)).font(Theme.mono(11))
                let fiat = money.fiatSubtitle(sats: Int64(account.balanceSats), priceUSD: priceUSD)
                if !fiat.isEmpty && !needsSync {
                    Text(fiat).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SidebarFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Button {
                state.showAddWallet()
            } label: {
                Label("Add account", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .disabled(state.isSample)
            .help(state.isSample ? "Turn off the sample wallet in Settings to add your own" : "Add a wallet from a device, file or xpub")

            Button {
                Task { await state.scanDevices() }
            } label: {
                StatusRow(icon: "externaldrive.connected.to.line.below", title: "Hardware devices", detail: deviceDetail, ok: !state.devices.isEmpty)
            }
            .buttonStyle(.plain)
            .help("Click to look for USB devices")

            Button {
                if state.needsServer { state.showSettings() }
                else { Task { await state.sync() } }
            } label: {
                StatusRow(icon: "server.rack", title: "Electrum server", detail: syncDetail, ok: syncOK)
            }
            .buttonStyle(.plain)
            .help("Click to sync now (⌘R)")
        }
    }

    private var deviceDetail: String {
        if state.isScanningDevices { return "Looking…" }
        switch state.devices.count {
        case 0: return "None connected"
        case 1: return "\(state.devices[0].model) connected"
        default: return "\(state.devices.count) connected"
        }
    }

    private var syncDetail: String {
        if state.isSample { return "Sample data" }
        if state.electrumURL.isEmpty { return "Not set up. Open Settings" }
        switch state.syncStatus {
        case .idle: return "Not synced yet"
        case .syncing: return "Syncing…"
        case .synced(let date): return "Synced \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): return message
        }
    }

    private var syncOK: Bool {
        if case .synced = state.syncStatus { return true }
        return false
    }
}

private struct StatusRow: View {
    let icon: String
    let title: String
    let detail: String
    var ok = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.textSecondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(2)
            }
            Spacer()
            Circle().fill(ok ? Theme.positive : Theme.textMuted).frame(width: 7, height: 7).accessibilityHidden(true)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
        .accessibilityElement(children: .combine)
    }
}
