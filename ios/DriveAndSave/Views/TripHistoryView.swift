import SwiftUI
import Charts

struct TripHistoryView: View {
    @EnvironmentObject private var model: AppViewModel
    var body: some View {
        Screen {
            if model.client.isMock { Text("Demo cost chart · device recordings labeled below").font(.caption).foregroundStyle(DS.secondary) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Every drive\ntells a story.").font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-0.8)
                Text("See where a smoother journey could take you.").foregroundStyle(DS.secondary)
            }
            Surface {
                Eyebrow(text: "Avoidable fuel cost by trip")
                Text(model.avoidableCost.dollars).font(.largeTitle.bold()).foregroundStyle(DS.mint)
                Text("Modeled total · sample trips").font(.caption).foregroundStyle(DS.secondary)
                Chart(model.estimatedTrips.sorted { $0.date < $1.date }) { trip in
                    BarMark(x: .value("Date", trip.date, unit: .day), y: .value("Estimated dollars", trip.avoidableCost))
                        .foregroundStyle(DS.mint.gradient).cornerRadius(5)
                        .accessibilityLabel(trip.title).accessibilityValue(trip.avoidableCost.dollars)
                }
                .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel { if let amount = value.as(Double.self) { Text(amount.dollars) } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 180)
            }
            Text("Trip archive").font(.title2.bold())
            Surface {
                if model.trips.isEmpty { ContentUnavailableView("No trips yet", systemImage: "car.side", description: Text("Completed drives will appear here.")) }
                ForEach(model.trips) { trip in
                    NavigationLink { TripReceiptView(trip: trip) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trip.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(DS.secondary)
                            TripRow(trip: trip)
                        }
                    }.buttonStyle(.plain)
                    if trip.id != model.trips.last?.id { Divider() }
                }
            }
        }.navigationTitle("Trip history").navigationBarTitleDisplayMode(.inline).refreshable { await model.load() }
    }
}
