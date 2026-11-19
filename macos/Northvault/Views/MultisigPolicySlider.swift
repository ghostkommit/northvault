import SwiftUI

/// Keep both handles within the supported M-of-N range, including M == N.
struct MultisigPolicy: Equatable {
    private(set) var required: Int
    private(set) var total: Int

    init(required: Int = 1, total: Int = 1) {
        self.total = min(15, max(1, total))
        self.required = min(self.total, max(1, required))
    }

    mutating func setRequired(_ value: Int) { required = min(total, max(1, value)) }
    mutating func setTotal(_ value: Int) {
        total = min(15, max(1, value))
        required = min(required, total)
    }

    var isMultisig: Bool { total > 1 }

    func compatibleScriptType(_ current: ScriptType) -> ScriptType {
        let supported = isMultisig ? ScriptType.multisig : ScriptType.singleSig
        return supported.contains(current) ? current : (isMultisig ? .p2wsh : .p2wpkh)
    }
}

struct MultisigPolicySlider: View {
    @Binding var policy: MultisigPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(policy.required) of \(policy.total)")
                    .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Text(policy.isMultisig ? "Multisig · signatures required to spend" : "Single signature")
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 48)
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Theme.borderStrong).frame(width: width, height: 6).offset(x: 24, y: 49)
                    Capsule().fill(Theme.accent.opacity(0.4))
                        .frame(width: position(policy.total, width: width), height: 6).offset(x: 24, y: 49)
                    Capsule().fill(Theme.accent)
                        .frame(width: position(policy.required, width: width), height: 6).offset(x: 24, y: 49)
                    ForEach(1...15, id: \.self) { value in
                        VStack(spacing: 5) {
                            Rectangle().fill(Theme.textMuted).frame(width: 1, height: 6)
                            Text("\(value)").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        }.frame(width: 24).offset(x: 12 + position(value, width: width), y: 96)
                    }
                    handle(required: true, width: width)
                    handle(required: false, width: width)
                }
                .coordinateSpace(name: "multisig-policy")
            }.frame(height: 120)
            Text("Drag the upper handle for required signatures and the lower handle for total keys.")
                .font(.caption).foregroundStyle(Theme.textMuted)
        }
        .padding(Theme.Space.l)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func position(_ value: Int, width: CGFloat) -> CGFloat { CGFloat(value - 1) / 14 * width }

    private func handle(required: Bool, width: CGFloat) -> some View {
        let value = required ? policy.required : policy.total
        return VStack(spacing: 0) {
            if !required { Rectangle().fill(Theme.accent).frame(width: 2, height: 8) }
            Text("\(value)")
                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .frame(width: 36, height: 36)
                .background(required ? Theme.accent : Theme.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
            if required { Rectangle().fill(Theme.accent).frame(width: 2, height: 8) }
        }
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .offset(x: position(value, width: width), y: required ? 4 : 52)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("multisig-policy"))
            .onChanged { gesture in
                let value = Int(((gesture.location.x - 24) / width * 14).rounded()) + 1
                if required { policy.setRequired(value) } else { policy.setTotal(value) }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(required ? "Required signatures" : "Total keys")
        .accessibilityValue("\(value)")
        .focusable()
        .onMoveCommand { direction in
            let delta = direction == .right || direction == .up ? 1 : -1
            if required { policy.setRequired(value + delta) } else { policy.setTotal(value + delta) }
        }
        .accessibilityAdjustableAction { direction in
            let value = value + (direction == .increment ? 1 : -1)
            if required { policy.setRequired(value) } else { policy.setTotal(value) }
        }
        .help(required ? "Required signatures" : "Total keys")
    }
}
