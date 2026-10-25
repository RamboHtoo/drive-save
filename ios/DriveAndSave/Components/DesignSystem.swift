import SwiftUI

enum DS {
    static let background = Color(hex: 0x0A0A0A)
    static let card = Color(hex: 0x141512)
    static let acid = Color(hex: 0xD4FB08)
    static let ink = Color(hex: 0xF1F0E8)
    static let signal = Color(hex: 0x777A73)
    // A brighter companion for small body copy; signal gray is reserved for graphic marks.
    static let secondary = Color(hex: 0xADAFA6)
    static let rule = Color(hex: 0x35372F)
    static let mint = acid // Compatibility for existing recording/settings views.
    static let technical = Font.system(.caption, design: .monospaced).weight(.medium)
    static let section = Font.system(.title2, design: .default).weight(.bold)
}

private extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

extension Double { var dollars: String { formatted(.currency(code: "USD")) } }

struct DisplayType: View {
    let text: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 48
    init(_ text: String, size: CGFloat = 48) { self.text = text; _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle) }
    var body: some View {
        Text(text).font(.system(size: size, weight: .black)).fontWidth(.condensed)
            .tracking(-size * 0.035).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(DS.ink)
    }
}

struct FinancialNumber: View {
    let value: String
    var ink: Color = DS.ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var size = 76.0
    var body: some View {
        Text(value).font(.system(size: size, weight: .semibold)).fontWidth(.condensed)
            .tracking(-size * 0.055).monospacedDigit().foregroundStyle(ink)
            .lineLimit(1).minimumScaleFactor(0.4)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: value)
    }
}

struct MeasurementRule: View {
    var body: some View { Rectangle().fill(DS.rule).frame(height: 1).accessibilityHidden(true) }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
            .overlay(alignment: .top) { MeasurementRule() }
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(DS.technical).tracking(1.5).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(DS.ink)
            Text(label).font(.caption).foregroundStyle(DS.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DemoNotice: View {
    var body: some View {
        Text("DEMO · SIMULATED DATA").font(DS.technical).foregroundStyle(DS.secondary)
            .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(DS.signal).frame(width: 2) }
    }
}

struct IgnitionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(DS.background)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
            .background(isEnabled ? DS.acid : DS.signal)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct TripRow: View {
    let trip: Trip
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { title; Spacer(minLength: 12); amount }
                VStack(alignment: .leading, spacing: 8) { title; amount }
            }
            Text(trip.provenanceLabel).font(.caption.monospaced()).foregroundStyle(DS.secondary)
            Text("\(trip.distanceLabel) · \(trip.durationLabel)").font(.caption.monospaced()).foregroundStyle(DS.secondary)
        }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { MeasurementRule() }
            .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    private var title: some View { Text(trip.displayTitle).font(.headline).foregroundStyle(DS.ink) }
    private var amount: some View {
        Text(trip.isWalkingTest ? "GPS test" : trip.hasEstimate ? trip.avoidableCost.dollars : "Pending")
            .font(.body.monospaced().weight(.semibold)).foregroundStyle(DS.ink)
    }
}

struct Screen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }.padding(20)
        }
        .contentMargins(.bottom, 24, for: .scrollContent)
        .foregroundStyle(DS.ink).background(DS.background)
        .buttonBorderShape(.roundedRectangle(radius: 4))
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(DS.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
    }
}
