import Foundation

@main struct LiveTelemetryTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BackendError.invalidInput("FAIL: " + message) }
        checks += 1; print("PASS: " + message)
    }
    static let start = Date(timeIntervalSince1970: 1_790_000_000)
    static func input(time: Double = 0, speed: Double? = 10, accuracy: Double? = 0.5, horizontal: Double = 5, device: Vector3? = .zero, forward: Double? = -0.2, lateral: Double? = 0.1, running: Bool = true, distance: Double? = 1.25, elapsed: Double = 61) -> LiveTelemetryInput {
        let timestamp = start.addingTimeInterval(time)
        return .init(isRecording: running, speed: speed.map { .init(timestamp: timestamp, metersPerSecond: $0, accuracyMetersPerSecond: accuracy, horizontalAccuracyMeters: horizontal) }, acceleration: device.map { .init(timestamp: timestamp, deviceG: $0, vehicleForwardG: forward, vehicleLateralG: lateral) }, elapsedSeconds: elapsed, distanceMiles: distance, isSynthetic: false)
    }
    static func main() throws {
        var display = LiveTelemetryDisplay()
        let raw = input()
        let first = display.update(raw, now: start)
        try check(abs((first.speedMPH ?? 0) - 22.369362921) < 1e-8, "GPS meters/second converts to MPH")
        try check(first.forwardG == -0.2 && first.lateralG == 0.1 && first.axes == .vehicle, "signed gravity-corrected vehicle g remains signed")
        try check(LiveTelemetrySnapshot.accelerationLabel(first.forwardG) == "-0.200 g" && LiveTelemetrySnapshot.accelerationLabel(first.lateralG) == "+0.100 g", "visible acceleration includes explicit negative and positive signs")
        try check(LiveTelemetrySnapshot.spokenAcceleration(-0.2) == "negative 0.200 g" && LiveTelemetrySnapshot.spokenAcceleration(0.1) == "positive 0.100 g", "VoiceOver can distinguish acceleration direction without color")
        try check(first.elapsedLabel == "01:01" && first.distanceLabel == "1.25 mi", "time and cumulative distance remain trip measurements")
        let nextRaw = input(time: 0.5, speed: 20, forward: -0.4, lateral: -0.2)
        let smoothed = display.update(nextRaw, now: start.addingTimeInterval(0.5))
        try check(smoothed.speedMPH! > first.speedMPH! && smoothed.speedMPH! < 44.738725842, "speed display smooths a noisy step without extrapolation")
        try check(smoothed.forwardG! < -0.2 && smoothed.forwardG! > -0.4 && smoothed.lateralG! < 0.1, "acceleration display smoothing preserves signed axes")
        try check(nextRaw.acceleration?.vehicleForwardG == -0.4 && nextRaw.speed?.metersPerSecond == 20 && raw.acceleration?.vehicleForwardG == -0.2, "display filtering never changes input measurements")
        let repeated = display.update(nextRaw, now: start.addingTimeInterval(0.7))
        try check(repeated.speedMPH == smoothed.speedMPH && repeated.forwardG == smoothed.forwardG, "polling a repeated observation does not apply more smoothing")
        let staleMotion = display.update(nextRaw, now: start.addingTimeInterval(1.6))
        try check(staleMotion.forwardG == nil && staleMotion.lateralG == nil && staleMotion.axes == .unavailable && staleMotion.speedMPH != nil, "motion becomes unavailable independently of GPS after one second")
        let stale = display.update(nextRaw, now: start.addingTimeInterval(3.6))
        try check(stale.speedLabel == "—" && LiveTelemetrySnapshot.accelerationLabel(stale.forwardG) == "—", "stale readings show dashes")
        try check(stale.distanceMiles == 1.25 && stale.elapsedSeconds == 61, "GPS staleness does not erase accumulated distance or elapsed time")
        let resumed = display.update(input(time: 4, speed: 5, forward: 0.3), now: start.addingTimeInterval(4))
        try check(resumed.forwardG == 0.3 && abs(resumed.speedMPH! - 11.1846814605) < 1e-8, "fresh readings after an outage restart without stale filter history")
        let phone = display.update(input(time: 4.5, device: .init(x: -0.15, y: 0.4, z: 0), forward: nil, lateral: nil), now: start.addingTimeInterval(4.5))
        try check(phone.axes == .device && phone.forwardG == 0.4 && phone.lateralG == -0.15, "invalid vehicle frame switches immediately to clearly labeled phone y/x axes")
        let mounted = display.update(input(time: 5, forward: -0.05, lateral: 0.06), now: start.addingTimeInterval(5))
        try check(mounted.axes == .vehicle && mounted.forwardG == -0.05 && mounted.lateralG == 0.06, "frame changes reset smoothing instead of blending phone and vehicle axes")
        for bad in [input(speed: -1), input(speed: .nan), input(speed: .infinity), input(accuracy: -1), input(accuracy: .nan), input(accuracy: nil), input(accuracy: 2.1), input(horizontal: -1), input(horizontal: 36)] {
            var isolated = LiveTelemetryDisplay()
            try check(isolated.update(bad, now: start).speedLabel == "—", "invalid or low-confidence GPS reading is unavailable")
        }
        var fresh = LiveTelemetryDisplay()
        let future = fresh.update(input(time: 1), now: start)
        try check(future.speedMPH == nil && future.forwardG == nil, "future-dated readings are not presented as current observations")
        let zero = fresh.update(input(speed: 0, forward: 0, lateral: 0), now: start)
        try check(zero.speedLabel == "0.0 MPH" && LiveTelemetrySnapshot.accelerationLabel(zero.forwardG) == "+0.000 g", "valid stationary zero readings are not mistaken for unavailable values")
        let invalidMotion = fresh.update(input(time: 0.5, device: .init(x: .nan, y: 0.1, z: 0)), now: start.addingTimeInterval(0.5))
        try check(invalidMotion.axes == .unavailable && invalidMotion.forwardG == nil && invalidMotion.lateralG == nil, "non-finite device acceleration cannot become a vehicle measurement")
        let ended = fresh.update(input(time: 1, running: false), now: start.addingTimeInterval(1))
        try check(ended.speedMPH == nil && ended.forwardG == nil && ended.distanceMiles == 1.25, "ending recording clears live readings but preserves trip totals")
        let missing = fresh.update(input(device: nil, distance: nil), now: start)
        try check(missing.distanceLabel == "—" && missing.axes == .unavailable, "no distance or motion is unavailable rather than fabricated zero")
        let tiny = fresh.update(input(distance: 0.001), now: start)
        try check(tiny.distanceLabel == "<0.01 mi", "small recorded distance is not rounded to a false zero")
        let invalidTotals = fresh.update(input(distance: .nan, elapsed: .nan), now: start)
        try check(invalidTotals.distanceLabel == "—" && invalidTotals.elapsedLabel == "—", "non-finite trip totals are safe for display")
        try check(LiveTelemetryDisplay.refreshInterval == 0.5, "presentation refresh is bounded at two Hz")
        print("\(checks) live telemetry checks passed.")
    }
}
