import SwiftUI

struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.Space.xl
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
    }
}

struct FieldModifier: ViewModifier {
    var invalid = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(invalid ? Theme.negative : Theme.borderStrong)
            )
    }
}

extension View {
    func card(padding: CGFloat = Theme.Space.xl) -> some View { modifier(CardModifier(padding: padding)) }
    func field(invalid: Bool = false) -> some View { modifier(FieldModifier(invalid: invalid)) }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textMuted)
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            Text(value).font(Theme.mono(16, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Space.l)
    }
}

struct InfoTile: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            Text(value).font(mono ? Theme.mono(13) : .body).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
    }
}

struct StatusPill: View {
    let pending: Bool
    var body: some View {
        Text(pending ? "Pending" : "Confirmed")
            .font(.system(size: 12, weight: pending ? .medium : .regular))
            .foregroundStyle(pending ? Theme.warning : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(pending ? Theme.warningBg : Theme.surfaceRaised, in: Capsule())
    }
}

struct DirectionBadge: View {
    let incoming: Bool
    var body: some View {
        Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(incoming ? Theme.incoming : Theme.textSecondary)
            .frame(width: 26, height: 26)
            .background(incoming ? Theme.incomingBg : Theme.border, in: Circle())
            .accessibilityLabel(incoming ? "Received" : "Sent")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .foregroundStyle(isEnabled ? Theme.onAccent : Theme.textMuted)
            .background(isEnabled ? Theme.accent : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .foregroundStyle(Theme.text)
            .background(configuration.isPressed ? Theme.borderStrong : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.borderStrong))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondary: SecondaryButtonStyle { .init() } }

/// Shared Table look for the dark theme.
extension View {
    func walletTable() -> some View {
        self
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
    }
}

/// Right-click → "Edit Label…" on any row value. Stored as BIP329 labels in Rust.
@MainActor
private struct LabelEditor: ViewModifier {
    @Environment(AppState.self) private var state
    let account: Account
    let kind: LabelKind
    let reference: String
    let current: String?
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Edit Label…") {
                state.editText("Edit label", value: current ?? "") { text in
                    try state.wallet.setLabel(accountId: account.id, kind: kind, reference: reference, label: text)
                    state.refresh()
                }
            }.disabled(state.isSample)
        }
    }

}

extension View {
    func labelEditor(account: Account, kind: LabelKind, reference: String, current: String?) -> some View {
        modifier(LabelEditor(account: account, kind: kind, reference: reference, current: current))
    }
}
