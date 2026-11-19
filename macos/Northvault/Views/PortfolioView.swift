import SwiftUI

/// "Total portfolio" selection: only the combined net worth chart.
struct PortfolioView: View {
    var body: some View {
        ScrollView {
            NetWorthCard(accountId: nil, title: "Total portfolio")
                .padding(Theme.Space.xxl)
                .frame(maxWidth: 1240)
        }
    }
}
