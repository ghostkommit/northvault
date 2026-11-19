import SwiftUI
import WalletUI
@main struct NorthvaultStorageApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView { EncryptedWalletsView() }
                    .navigationTitle("Northvault")
            }
        }
    }
}
