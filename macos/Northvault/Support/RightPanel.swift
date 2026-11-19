import SwiftUI
import WalletUI

struct PanelPage: Identifiable {
    let id = UUID()
    let title: String
    let content: AnyView
    let centered: Bool
    let showsHeader: Bool
    let fillsWorkspace: Bool
    let onClose: () -> Void
}

struct DismissPanelAction {
    var action: () -> Void = {}
    func callAsFunction() { action() }
}
private struct DismissPanelKey: EnvironmentKey {
    static let defaultValue = DismissPanelAction()
}
extension EnvironmentValues {
    var dismissPanel: DismissPanelAction {
        get { self[DismissPanelKey.self] }
        set { self[DismissPanelKey.self] = newValue }
    }
}

@MainActor
extension AppState {
    var navigationTitle: String {
        panelPages.last(where: { !$0.showsHeader })?.title
            ?? selectedAccount?.name ?? "Total portfolio"
    }

    @discardableResult
    func presentPanel<V: View>(_ title: String, centered: Bool = false, showsHeader: Bool = true, fillsWorkspace: Bool = false, onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> V) -> UUID {
        let page = PanelPage(title: title, content: AnyView(content()), centered: centered, showsHeader: showsHeader, fillsWorkspace: fillsWorkspace, onClose: onClose)
        panelPages.append(page)
        return page.id
    }

    func closePanel(_ id: UUID) {
        guard let index = panelPages.firstIndex(where: { $0.id == id }) else { return }
        let removed = Array(panelPages[index...])
        panelPages.removeSubrange(index...)
        for page in removed.reversed() { page.onClose() }
    }

    func closeAllPanels() {
        if let first = panelPages.first { closePanel(first.id) }
    }

    func selectSidebarItem(_ item: SidebarItem?) {
        closeAllPanels()
        selection = item
        section = .transactions
    }

    func presentAccountPanel<V: View>(_ title: String, @ViewBuilder content: () -> V) {
        closeAllPanels()
        section = .transactions
        presentPanel(title, showsHeader: false) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: Theme.Space.xxl)
                .padding(Theme.Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func showAddWallet() {
        closeAllPanels()
        presentPanel("Add account", showsHeader: false, fillsWorkspace: true) { AddWalletSheet() }
    }
    func showSettings() { presentPanel("Settings", showsHeader: false) { SettingsView() } }

    func confirm(_ title: String, message: String, actionTitle: String, destructive: Bool = false, action: @escaping () throws -> Void) {
        presentPanel(title) {
            PanelConfirmation(message: message, actionTitle: actionTitle, destructive: destructive, action: action)
                .padding(Theme.Space.xxl).frame(maxWidth: 700, alignment: .leading)
        }
    }

    func editText(_ title: String, value: String, actionTitle: String = "Save", action: @escaping (String) throws -> Void) {
        presentPanel(title) {
            PanelTextEditor(initial: value, actionTitle: actionTitle, action: action)
                .padding(Theme.Space.xxl).frame(maxWidth: 700)
        }
    }
}

@MainActor
struct RightPanelPages: View {
    @Environment(AppState.self) private var state
    var body: some View {
        ZStack {
            ForEach(state.panelPages) { page in
                VStack(spacing: 0) {
                    if page.showsHeader {
                        HStack {
                            Button { state.closePanel(page.id) } label: { Label("Back", systemImage: "chevron.left") }
                                .buttonStyle(.secondary)
                            Text(page.title).font(.headline)
                            Spacer()
                        }
                        .padding(Theme.Space.l)
                        Divider()
                    }
                    GeometryReader { geometry in
                        if page.fillsWorkspace {
                            page.content
                                .environment(\.dismissPanel, DismissPanelAction { state.closePanel(page.id) })
                                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        } else {
                            ScrollView {
                                page.content
                                    .environment(\.dismissPanel, DismissPanelAction { state.closePanel(page.id) })
                                    .frame(maxWidth: .infinity, minHeight: page.centered ? geometry.size.height : 0,
                                           alignment: page.centered ? .center : .topLeading)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.ground)
                .opacity(state.panelPages.last?.id == page.id ? 1 : 0)
                .allowsHitTesting(state.panelPages.last?.id == page.id)
                .disabled(state.panelPages.last?.id != page.id)
                .accessibilityHidden(state.panelPages.last?.id != page.id)
            }
        }
    }
}

@MainActor
struct PanelConfirmation: View {
    @Environment(\.dismissPanel) private var dismiss
    let message: String
    let actionTitle: String
    let destructive: Bool
    let action: () throws -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(message).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(Theme.negative) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.secondary)
                Button(actionTitle, role: destructive ? .destructive : nil) {
                    do { try action(); dismiss() } catch { self.error = error.userMessage }
                }.buttonStyle(.primary)
            }
        }
    }
}

@MainActor
struct PanelTextEditor: View {
    @Environment(\.dismissPanel) private var dismiss
    let initial: String
    var fieldLabel = "Value"
    let actionTitle: String
    let action: (String) throws -> Void
    @State private var value = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(fieldLabel).font(.headline)
            TextField(fieldLabel, text: $value).field()
            if let error { Text(error).foregroundStyle(Theme.negative) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.secondary)
                Button(actionTitle) {
                    do { try action(value); dismiss() } catch { self.error = error.userMessage }
                }.buttonStyle(.primary)
            }
        }.onAppear { value = initial }
    }
}
