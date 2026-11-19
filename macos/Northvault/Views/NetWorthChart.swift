import SwiftUI
import Charts

struct ChartPoint: Identifiable {
    let date: Date
    let value: Double   // in the display currency
    let sats: Int64
    let priceUSD: Double
    var id: Date { date }
}

/// Header + chart card. `accountId == nil` shows the whole portfolio.
struct NetWorthCard: View {
    @Environment(AppState.self) private var state
    let accountId: String?
    let title: String
    @State private var hovered: Date?

    var body: some View {
        @Bindable var state = state
        let money = state.money
        let needsSync = state.historyNeedsSync(accountId: accountId)
        let points = state.wallet
            .netWorthHistory(accountId: accountId, range: state.range)
            .map {
                ChartPoint(
                    date: Date(unix: $0.timestamp),
                    value: money.amount(sats: Int64($0.balanceSats), priceUSD: $0.btcPriceUsd),
                    sats: Int64($0.balanceSats),
                    priceUSD: $0.btcPriceUsd
                )
            }
        let first = points.first?.value ?? 0
        let last = points.last?.value ?? 0

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Net worth · \(title)")
                    Text(needsSync ? "Not synced" : (money.currency == .btc ? money.bitcoin(points.last?.sats ?? 0) : money.number(last)))
                        .font(.system(size: 34, weight: .semibold))
                        .monospacedDigit()
                    if !needsSync { ChangeLabel(first: first, last: last, money: money, phrase: state.range.phrase) }
                }
                Spacer()
                Picker("Time range", selection: $state.range) {
                    ForEach(TimeRange.all, id: \.self) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .labelsHidden()
                .fixedSize()

                Button { state.showSettings() } label: {
                    HStack(spacing: 6) {
                        Text("Shown in").foregroundStyle(Theme.textMuted)
                        Text(state.currency.rawValue).fontWeight(.semibold)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderStrong))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Change the display currency in Settings")
            }

            if needsSync {
                VStack(spacing: Theme.Space.m) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle)
                    Text("Sync to download balances and transaction history")
                    if !state.needsServer {
                        Button("Sync now") { Task { await state.sync() } }.buttonStyle(.primary)
                            .disabled(state.syncStatus == .syncing)
                    }
                }.frame(maxWidth: .infinity).frame(height: 260).foregroundStyle(Theme.textMuted)
            } else {
            NetWorthChart(points: points, money: money, hovered: $hovered)
                .frame(height: 260)
                .accessibilityLabel("Net worth of \(title) over the \(state.range.phrase) in \(state.currency.rawValue)")
            }
        }
        .card()
    }
}

private struct ChangeLabel: View {
    let first: Double
    let last: Double
    let money: MoneyFormat
    let phrase: String

    var body: some View {
        let diff = last - first
        let up = diff >= 0
        HStack(spacing: 6) {
            if money.hidden {
                Text("•••")
            } else {
                Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 9))
                Text(money.number(diff, signed: true))
                if first > 0 {
                    Text(verbatim: String(format: "(%@%.2f%%)", up ? "+" : "−", abs(diff / first * 100)))
                }
            }
            Text(phrase).foregroundStyle(Theme.textMuted)
        }
        .font(.system(size: 13))
        .foregroundStyle(up ? Theme.positive : Theme.negative)
    }
}

struct NetWorthChart: View {
    let points: [ChartPoint]
    let money: MoneyFormat
    @Binding var hovered: Date?

    private var selected: ChartPoint? {
        guard let hovered else { return nil }
        return points.min { abs($0.date.timeIntervalSince(hovered)) < abs($1.date.timeIntervalSince(hovered)) }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard var lo = values.min(), var hi = values.max() else { return 0...1 }
        if hi - lo < 1e-9 { hi = hi * 1.05 + 1e-6; lo *= 0.95 }
        let pad = (hi - lo) * 0.15
        return max(0, lo - pad)...(hi + pad)
    }

    var body: some View {
        let domain = yDomain
        let spansYears = (points.last?.date.timeIntervalSince(points.first?.date ?? .now) ?? 0) > 366 * 86_400
        Chart {
            ForEach(points) { p in
                AreaMark(
                    x: .value("Date", p.date),
                    yStart: .value("Base", domain.lowerBound),
                    yEnd: .value("Net worth", p.value)
                )
                .foregroundStyle(Theme.accent.opacity(0.12))

                LineMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }

            if let s = selected {
                RuleMark(x: .value("Date", s.date))
                    .foregroundStyle(Theme.borderStrong)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(point: s, money: money)
                    }
                PointMark(x: .value("Date", s.date), y: .value("Net worth", s.value))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(70)
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: spansYears ? .dateTime.month(.abbreviated).year() : .dateTime.month(.abbreviated).day())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.border)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(money.axis(v)) }
                }
                .foregroundStyle(Theme.textMuted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            hovered = proxy.value(atX: location.x - geo[plot].origin.x, as: Date.self)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }
}

private struct ChartTooltip: View {
    let point: ChartPoint
    let money: MoneyFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.date, format: .dateTime.month(.abbreviated).day().year())
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Text(money.currency == .btc ? money.bitcoin(point.sats) : money.number(point.value)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            if money.currency != .btc {
                Text(money.bitcoin(point.sats)).font(Theme.mono(11)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}
