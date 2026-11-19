import SwiftUI
import WalletUI

@MainActor
struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 296, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if state.needsServer {
                    HStack(alignment: .top) {
                        Image(systemName: "network.slash")
                        Text("Configure an Electrum server to download transaction history. Your hardware device supplies keys; history comes from the server.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Configure server") { state.showSettings() }.buttonStyle(.primary)
                    }.padding(Theme.Space.l).background(Theme.surfaceRaised)
                } else if case .failed(let message) = state.syncStatus {
                    HStack(alignment: .top) {
                        Text("Sync failed. Displayed data may be incomplete. \(message)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry") { Task { await state.sync() } }.buttonStyle(.secondary)
                        Button("Settings") { state.showSettings() }.buttonStyle(.secondary)
                    }.padding(Theme.Space.l).background(Theme.surfaceRaised)
                }
                if let message = state.alertMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss") { state.alertMessage = nil }.buttonStyle(.secondary)
                    }.padding(Theme.Space.l).background(Theme.surfaceRaised)
                }
                ZStack {
                    Group {
                        if let account = state.selectedAccount {
                            AccountDetailView(account: account).id(account.id)
                        } else {
                            PortfolioView()
                        }
                    }
                    .opacity(state.panelPages.isEmpty ? 1 : 0)
                    .allowsHitTesting(state.panelPages.isEmpty)
                    .disabled(!state.panelPages.isEmpty)
                    .accessibilityHidden(!state.panelPages.isEmpty)
                    RightPanelPages()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
        }
        .navigationTitle(state.navigationTitle)
        .navigationSubtitle(subtitle)
        .toolbarBackground(Theme.sidebar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onChange(of: state.selection) { _, _ in state.closeAllPanels() }
        .onDisappear { state.closeAllPanels() }
        .toolbar {
            // The "top bar": Transactions / Send / Receive / Addresses / UTXOs.
            if state.selectedAccount != nil && state.panelPages.isEmpty {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $state.section) {
                        ForEach(AccountSection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let account = state.selectedAccount, !state.isSample {
                    AccountMenu(account: account)
                }

                Button { state.showSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
    }

    private var subtitle: String {
        if let account = state.selectedAccount {
            return "\(account.policy) · \(account.standard)"
        }
        if state.isSample { return "Sample data" }
        return "\(state.accounts.count) accounts combined · \(state.network.title)"
    }
}
