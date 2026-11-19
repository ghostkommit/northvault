import SwiftUI

struct AccountDetailView: View {
    @Environment(AppState.self) private var state
    let account: Account

    var body: some View {
        switch state.section {
        case .transactions: TransactionsView(account: account)
        case .send: SendView(account: account)
        case .receive: ReceiveView(account: account)
        case .addresses: AddressesView(account: account)
        case .utxos: UtxosView(account: account)
        }
    }
}
