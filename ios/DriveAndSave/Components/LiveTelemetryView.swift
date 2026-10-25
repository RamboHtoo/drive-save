import SwiftUI

/// A quiet parked-review panel. No live-region announcements, sounds or value animations.
struct LiveTelemetryView: View {
    let recorder: TripRecordingService
    let mountingConfirmed: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var display = LiveTelemetryDisplay()
    @State private var snapshot = LiveTelemetrySnapshot()
    private var metricLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            metricLayout {
                reading("Elapsed time", value: snapshot.elapsedLabel, spoken: snapshot.elapsedLabel, id: "elapsedTime")
                reading("Trip distance", value: snapshot.distanceLabel, spoken: snapshot.distanceMiles == nil ? "Unavailable" : snapshot.distanceLabel, id: "liveTripDistance")
            }
            reading(snapshot.isSynthetic ? "Simulated GPS speed" : "GPS speed", value: snapshot.speedLabel, spoken: snapshot.speedMPH.map { String(format: "%.1f miles per hour", $0) } ?? "Unavailable", id: "liveGPSSpeed")
            Text(snapshot.axes == .vehicle ? (snapshot.isSynthetic ? "Simulated vehicle acceleration" : "Mounted vehicle acceleration") : snapshot.axes == .device ? "Phone acceleration · device axes" : "Acceleration unavailable")
                .font(.caption).foregroundStyle(DS.secondary).accessibilityIdentifier("liveAccelerationAxes")
            metricLayout {
                reading(snapshot.axes == .device ? "Device Y" : "Forward", value: LiveTelemetrySnapshot.accelerationLabel(snapshot.forwardG), spoken: LiveTelemetrySnapshot.spokenAcceleration(snapshot.forwardG), id: "liveForwardAcceleration")
                reading(snapshot.axes == .device ? "Device X" : "Lateral", value: LiveTelemetrySnapshot.accelerationLabel(snapshot.lateralG), spoken: LiveTelemetrySnapshot.spokenAcceleration(snapshot.lateralG), id: "liveLateralAcceleration")
            }
            Text(snapshot.isSynthetic ? "Simulated telemetry · not live sensor measurements." : "Parked review only. Not a speedometer.")
                .font(.caption).foregroundStyle(DS.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trip telemetry")
        .transaction { $0.animation = nil }
        .task {
            while !Task.isCancelled {
                update()
                do { try await Task.sleep(for: .seconds(LiveTelemetryDisplay.refreshInterval)) }
                catch { return }
            }
        }
        .onChange(of: recorder.isRecording) { _, _ in update() }
    }
    private func update() {
        let now = Date()
        let next = display.update(recorder.liveTelemetryInput(mountingConfirmed: mountingConfirmed), now: now)
        if snapshot != next { snapshot = next }
    }
    private func reading(_ label: String, value: String, spoken: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(DS.ink)
            Text(label).font(.caption).foregroundStyle(DS.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(label).accessibilityValue(spoken)
            .accessibilityIdentifier(id)
    }
}
