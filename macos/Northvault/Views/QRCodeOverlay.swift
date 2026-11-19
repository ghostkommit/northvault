import SwiftUI

@MainActor
struct QRCodeOverlay: View {
    let title: String
    let model: QRCodeSequence
    let dismiss: () -> Void
    var cardRegion: QRCodeCardRegion? = nil

    var body: some View {
        GeometryReader { geometry in
            let side = max(180, min(420, min(geometry.size.width - 112, geometry.size.height - 220)))
            ZStack {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Close QR code")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { dismiss() }
                VStack(spacing: Theme.Space.l) {
                    Text(title).font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    Group {
                        if let error = model.error {
                            VStack(spacing: Theme.Space.m) {
                                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                                Text(error).multilineTextAlignment(.center)
                            }.foregroundStyle(Theme.textSecondary)
                                .frame(width: side, height: side)
                        } else if !model.images.isEmpty {
                            Image(decorative: model.images[model.index], scale: 1)
                                .interpolation(.none).resizable().scaledToFit()
                                .frame(width: side, height: side)
                                .accessibilityLabel("QR code with Northvault logo")
                        } else {
                            ProgressView("Preparing QR code…").frame(width: side, height: side)
                        }
                    }
                    if model.images.count > 1 {
                        Text("Frame \(model.index + 1) of \(model.images.count) · Keep scanning until your device finishes")
                            .font(.caption).foregroundStyle(Theme.textMuted)
                            .monospacedDigit()
                    }
                    Text("Click outside or press Esc to close")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                }
                .padding(Theme.Space.xxl)
                .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.borderStrong))
                .background {
                    if let cardRegion {
                        QRCodeCardAnchor(region: cardRegion)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.preferredColorScheme(.dark)
    }
}

/// A native view tracks the card's live bounds as loading/error/frame content changes.
/// It draws nothing and does not intercept clicks on the QR card.
private struct QRCodeCardAnchor: NSViewRepresentable {
    let region: QRCodeCardRegion

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        region.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { region.view = view }
}
