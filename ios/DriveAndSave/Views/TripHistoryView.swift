import SwiftUI
import Charts

struct TripHistoryView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var includeWalkingTests = false
    private var visibleTrips: [Trip] { includeWalkingTests ? model.trips : model.drivingTrips }
    var body: some View {
        Screen {
            DisclosureGroup("Cost trend") {
                DemoNotice()
                Text("Sample estimates · not measured savings").font(.caption).foregroundStyle(DS.secondary)
                Chart(model.estimatedTrips.sorted { $0.date < $1.date }) { trip in
                    BarMark(x: .value("Date", trip.date, unit: .day), y: .value("Estimated dollars", trip.avoidableCost))
                        .foregroundStyle(DS.acid)
                        .accessibilityLabel(trip.title).accessibilityValue(trip.avoidableCost.dollars)
                }
                .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel { if let amount = value.as(Double.self) { Text(amount.dollars) } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 180)
            }
            Toggle("Include Walking Tests", isOn: $includeWalkingTests).accessibilityIdentifier("includeWalkingTests")
            Text("Walking Tests are excluded from costs and rankings.").font(.caption).foregroundStyle(DS.secondary)
            VStack(alignment: .leading, spacing: 16) {
                if visibleTrips.isEmpty { ContentUnavailableView("No trips yet", systemImage: "car.side", description: Text("Completed drives will appear here.")) }
                ForEach(visibleTrips) { trip in
                    NavigationLink { TripReceiptView(trip: trip) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(DS.secondary)
                            TripRow(trip: trip)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("historyTrip-\(trip.title)")
                }
            }
        }.navigationTitle("Trip history").navigationBarTitleDisplayMode(.inline).refreshable { await model.load() }
    }
}
