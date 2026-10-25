import SwiftUI
import Charts

struct TripTimeline: View {
    let trip: Trip
    private var events: [DrivingEvent] { trip.isWalkingTest ? [] : trip.recording?.events.sorted { $0.timestamp < $1.timestamp } ?? [] }
    private var speeds: [APISpeedSample] {
        (trip.recording?.speedSamples ?? []).filter { $0.speed_mps.map { $0.isFinite && $0 >= 0 } ?? false }.sorted { $0.ts < $1.ts }
    }
    var body: some View {
        Surface {
            Eyebrow(text: trip.isWalkingTest ? "GPS observations / time" : "Driving timeline / observations")
            if !speeds.isEmpty {
                Chart(speeds, id: \.sample_seq) { sample in
                    if let speed = sample.speed_mps {
                        PointMark(x: .value("Time", sample.ts), y: .value("Speed, meters per second", speed))
                            .foregroundStyle(DS.acid).symbolSize(10)
                            .accessibilityLabel(sample.ts.formatted(date: .omitted, time: .standard))
                            .accessibilityValue("\(speed.formatted()) meters per second")
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(DS.rule); AxisValueLabel().foregroundStyle(DS.secondary) } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(DS.secondary) } }
                .frame(height: 160).accessibilityLabel("Timestamped GPS speed observations, in meters per second")
                Text(trip.source == .simulated ? "SIMULATED GPS · SPEED IN M/S" : "DEVICE GPS · SPEED IN M/S").font(DS.technical).foregroundStyle(DS.secondary)
                Text("Points are observations. Missing intervals are not joined or interpolated.").font(.caption).foregroundStyle(DS.secondary)
            }
            if !events.isEmpty {
                Chart(events) { event in
                    PointMark(x: .value("Time", event.timestamp), y: .value("Candidate event", event.kind.label))
                        .foregroundStyle(DS.ink).symbol(.diamond).symbolSize(36)
                        .accessibilityLabel(event.kind.label)
                        .accessibilityValue(event.timestamp.formatted(date: .omitted, time: .standard))
                }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().foregroundStyle(DS.secondary) } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()).foregroundStyle(DS.secondary) } }
                .frame(height: 120).accessibilityLabel("Candidate event timestamps by event category")
                ForEach(events) { event in
                    ReceiptLedgerLine(label: event.kind.label, value: event.timestamp.formatted(date: .omitted, time: .standard))
                }
                Text("Candidate classifications, not confirmed unsafe maneuvers.").font(.caption).foregroundStyle(DS.secondary)
            }
            if speeds.isEmpty && events.isEmpty {
                Text("No timestamped observations available.").font(.headline)
                Text("This receipt has no recorded timeline to display. Aggregate counts are not converted into invented event times.").font(.subheadline).foregroundStyle(DS.secondary)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("tripTimeline")
    }
}
