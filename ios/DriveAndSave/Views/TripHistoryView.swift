import SwiftUI

struct TripHistoryView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var backend: BackendViewModel
    @AppStorage("developerMode") private var developerMode = false
    @State private var includeWalkingTests = false
    private var visibleTrips: [Trip] {
        model.trips.filter { trip in
            (developerMode || !backend.isRemote || trip.source == .measured) &&
            (!trip.isWalkingTest || (developerMode && includeWalkingTests))
        }
    }
    var body: some View {
        Screen {
            if !backend.isRemote { Text("Offline demo · sample trips").font(.caption).foregroundStyle(DS.secondary) }
            if developerMode {
                Toggle("Include Walking Tests", isOn: $includeWalkingTests).accessibilityIdentifier("includeWalkingTests")
                Text("Walking Tests are excluded from costs and rankings.").font(.caption).foregroundStyle(DS.secondary)
            }
            if visibleTrips.isEmpty { ContentUnavailableView("No trips yet", systemImage: "car.side", description: Text("Completed drives will appear here.")) }
            ForEach(visibleTrips) { trip in
                NavigationLink { TripReceiptView(trip: trip) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(trip.date.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(amount(for: trip)).fontWeight(.semibold)
                        }
                        if developerMode { Text(trip.displayTitle).font(.headline) }
                        Text(trip.isIncompleteRecording ? "Incomplete recording" : trip.distanceLabel).font(.subheadline).foregroundStyle(DS.secondary)
                        if trip.source == .simulated { Text("Demo").font(.caption).foregroundStyle(DS.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(DS.ink).padding(.vertical, 16)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) { MeasurementRule() }
                }.buttonStyle(.plain).accessibilityIdentifier("historyTrip-\(trip.title)")
            }
        }.navigationTitle("Trip history").navigationBarTitleDisplayMode(.inline).refreshable { await model.load() }
    }
    private func amount(for trip: Trip) -> String {
        if trip.isWalkingTest { return "GPS test" }
        if let receipt = backend.receipt(for: trip) { return "Est. " + receipt.avoidable_cost_usd.receiptDollars }
        if trip.isIncompleteRecording { return "" }
        return trip.hasEstimate ? "Est. " + trip.avoidableCost.dollars : "Pending"
    }
}
