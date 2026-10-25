import SwiftUI
import Charts

/// Original static lane study. It is a brand illustration, never a sensor trace or score.
struct MotionLanes: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width, height = size.height
            for tick in 0...30 {
                let x = width * Double(tick) / 30
                var mark = Path(); mark.move(to: CGPoint(x: x, y: height - 8)); mark.addLine(to: CGPoint(x: x, y: height - (tick % 5 == 0 ? 18 : 12)))
                context.stroke(mark, with: .color(DS.signal), lineWidth: 1)
            }
            for lane in 0..<7 {
                let offset = Double(lane) * 15
                var path = Path(); path.move(to: CGPoint(x: -40, y: height * 0.85 - offset * 0.2))
                path.addCurve(to: CGPoint(x: width + 30, y: 14 + offset * 0.2), control1: CGPoint(x: width * 0.40, y: height * 0.85 - offset), control2: CGPoint(x: width * 0.42, y: -30 + offset))
                context.stroke(path, with: .color(lane == 3 ? DS.acid : DS.rule), lineWidth: lane == 3 ? 2 : 1)
            }
        }.frame(height: 130).clipped().accessibilityHidden(true)
    }
}

struct TelemetryGraphic: View {
    let trip: Trip?
    private var samples: [APISpeedSample] {
        trip?.recording?.speedSamples?.filter { sample in
            guard let speed = sample.speed_mps else { return false }
            return speed.isFinite && speed >= 0
        }.sorted { $0.ts < $1.ts } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Eyebrow(text: "Telemetry"); Spacer(); Text(samples.isEmpty ? "STANDBY" : "SPEED / M/S").font(DS.technical).foregroundStyle(DS.secondary) }
            if samples.isEmpty {
                MotionLanes()
                Text("No speed data yet.").font(.headline)
                Text("Illustration · record a trip to see GPS speeds.").font(.caption).foregroundStyle(DS.secondary)
            } else {
                Chart(samples, id: \.sample_seq) { sample in
                    if let speed = sample.speed_mps {
                        PointMark(x: .value("Time", sample.ts), y: .value("Speed, meters per second", speed))
                            .foregroundStyle(DS.acid).symbolSize(10)
                            .accessibilityLabel(sample.ts.formatted(date: .omitted, time: .standard))
                            .accessibilityValue("\(speed.formatted()) meters per second")
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(DS.rule); AxisValueLabel().foregroundStyle(DS.secondary) } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(DS.secondary) } }
                .frame(height: 140).accessibilityLabel("Timestamped GPS speeds; gaps are not interpolated")
                Text(trip?.source == .simulated ? "SIMULATED SPEED TRACE" : "RECORDED GPS").font(DS.technical).foregroundStyle(DS.secondary)
                Text("\(trip?.displayTitle ?? "Drive") · gaps excluded.").font(.caption).foregroundStyle(DS.secondary)
            }
        }.accessibilityIdentifier("telemetryGraphic")
    }
}
