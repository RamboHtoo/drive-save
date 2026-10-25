import SwiftUI

enum DS {
    static let background = Color(red: 0.035, green: 0.065, blue: 0.12)
    static let card = Color(red: 0.07, green: 0.115, blue: 0.18)
    static let mint = Color(red: 0.43, green: 0.94, blue: 0.76)
    static let secondary = Color(red: 0.64, green: 0.71, blue: 0.80)
}

extension Double {
    var dollars: String { formatted(.currency(code: "USD")) }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.05)))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.caption.weight(.bold)).tracking(2).foregroundStyle(DS.secondary) }
}

struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title2.bold()).foregroundStyle(.white)
            Text(label).font(.caption).foregroundStyle(DS.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DemoNotice: View {
    var body: some View {
        Label("DEMO · SIMULATED DATA", systemImage: "sparkles")
            .font(.caption2.bold()).tracking(1).foregroundStyle(DS.mint)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(DS.mint.opacity(0.10), in: Capsule())
    }
}

struct TripRow: View {
    let trip: Trip
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: trip.isWalkingTest ? "figure.walk" : "car.side.fill").font(.title3).foregroundStyle(DS.mint)
                .frame(width: 46, height: 46).background(DS.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(trip.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(trip.provenanceLabel).font(.system(size: 9, weight: .bold)).foregroundStyle(trip.source == .measured ? DS.mint : DS.secondary)
                Text("\(trip.distanceLabel) · \(trip.durationLabel)").font(.caption).foregroundStyle(DS.secondary)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 5) {
                Text(trip.isWalkingTest ? "GPS test" : trip.hasEstimate ? trip.avoidableCost.dollars : "Pending").font(.subheadline.bold()).foregroundStyle(DS.mint)
                Text(trip.isWalkingTest ? "no fuel costs" : trip.hasEstimate ? "avoidable" : "estimate").font(.caption2).foregroundStyle(DS.secondary)
            }
            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(DS.secondary)
        }.padding(.vertical, 8).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct Screen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(20)
        }
            // TabView supplies the native tab bar safe area. Keep the extra breathing room
            // inside the scrolling content, so the last message can scroll above the bar
            // without shrinking or clipping the viewport with a second tab bar reservation.
            .contentMargins(.bottom, 24, for: .scrollContent)
            .background(DS.background).toolbarBackground(DS.background, for: .navigationBar)
    }
}
