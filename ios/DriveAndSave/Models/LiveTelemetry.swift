import Foundation

/// Presentation inputs only. Never persisted or used by the detector, upload builder or scoring.
struct LiveTelemetryInput {
    struct Speed {
        let timestamp: Date
        let metersPerSecond: Double
        let accuracyMetersPerSecond: Double?
        let horizontalAccuracyMeters: Double
    }
    struct Acceleration {
        let timestamp: Date
        let deviceG: Vector3 // CMDeviceMotion.userAcceleration: gravity already removed, in g.
        let vehicleForwardG: Double?
        let vehicleLateralG: Double?
    }
    let isRecording: Bool
    let speed: Speed?
    let acceleration: Acceleration?
    let elapsedSeconds: Double
    let distanceMiles: Double?
    let isSynthetic: Bool
}

struct LiveTelemetrySnapshot: Equatable {
    enum Axes { case vehicle, device, unavailable }
    var speedMPH: Double?
    var forwardG: Double?
    var lateralG: Double?
    var axes: Axes = .unavailable
    var elapsedSeconds = 0.0
    var distanceMiles: Double?
    var isSynthetic = false

    static func accelerationLabel(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%+.3f g", value)
    }
    static func spokenAcceleration(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%@ %.3f g", value.sign == .minus ? "negative" : "positive", abs(value))
    }
    var speedLabel: String { speedMPH.map { String(format: "%.1f MPH", $0) } ?? "—" }
    var distanceLabel: String { distanceMiles.map { $0 > 0 && $0 < 0.01 ? "<0.01 mi" : String(format: "%.2f mi", $0) } ?? "—" }
    var elapsedLabel: String {
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0, elapsedSeconds < Double(Int.max) else { return "—" }
        let seconds = Int(elapsedSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Time-based, display-only smoothing. A repeated sample never advances the filter.
struct LiveTelemetryDisplay {
    static let refreshInterval = 0.5
    static let speedMaximumAge = 3.0
    static let motionMaximumAge = 1.0
    private var speed = Smoother()
    private var forward = Smoother()
    private var lateral = Smoother()
    private var axes = LiveTelemetrySnapshot.Axes.unavailable
    private var synthetic: Bool?

    mutating func update(_ input: LiveTelemetryInput, now: Date) -> LiveTelemetrySnapshot {
        if synthetic != input.isSynthetic { speed = Smoother(); forward = Smoother(); lateral = Smoother() }
        synthetic = input.isSynthetic
        var result = LiveTelemetrySnapshot(elapsedSeconds: input.elapsedSeconds, distanceMiles: input.distanceMiles.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, isSynthetic: input.isSynthetic)
        let gps = input.speed
        let validGPS = input.isRecording && gps.map {
            fresh($0.timestamp, now: now, maximumAge: Self.speedMaximumAge) &&
            $0.metersPerSecond.isFinite && $0.metersPerSecond >= 0 &&
            $0.accuracyMetersPerSecond.map { $0.isFinite && (0...2).contains($0) } == true &&
            $0.horizontalAccuracyMeters.isFinite && (0...35).contains($0.horizontalAccuracyMeters)
        } == true
        result.speedMPH = speed.update(value: validGPS ? gps.map { $0.metersPerSecond * 2.2369362921 } : nil, timestamp: gps?.timestamp)

        let motion = input.acceleration
        let validMotion = input.isRecording && motion.map {
            fresh($0.timestamp, now: now, maximumAge: Self.motionMaximumAge) &&
            [$0.deviceG.x, $0.deviceG.y, $0.deviceG.z].allSatisfy(\.isFinite)
        } == true
        let vehicle = validMotion && motion?.vehicleForwardG?.isFinite == true && motion?.vehicleLateralG?.isFinite == true
        let newAxes: LiveTelemetrySnapshot.Axes = validMotion ? (vehicle ? .vehicle : .device) : .unavailable
        if axes != newAxes { forward = Smoother(); lateral = Smoother() }
        axes = newAxes
        result.axes = axes
        // Phone y/x are explicitly labeled as device axes, never vehicle forward/lateral.
        let forwardValue = validMotion ? (vehicle ? motion?.vehicleForwardG : motion?.deviceG.y) : nil
        let lateralValue = validMotion ? (vehicle ? motion?.vehicleLateralG : motion?.deviceG.x) : nil
        result.forwardG = forward.update(value: forwardValue, timestamp: motion?.timestamp)
        result.lateralG = lateral.update(value: lateralValue, timestamp: motion?.timestamp)
        return result
    }
    private func fresh(_ timestamp: Date, now: Date, maximumAge: Double) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && (0...maximumAge).contains(age)
    }
    private struct Smoother {
        var value: Double?
        var timestamp: Date?
        mutating func update(value incoming: Double?, timestamp date: Date?) -> Double? {
            guard let incoming, incoming.isFinite, let date else { self = Smoother(); return nil }
            if let timestamp {
                let dt = date.timeIntervalSince(timestamp)
                guard dt >= 0 else { value = nil; return nil }
                if dt == 0 { return value }
                // Restart after observation gaps instead of mixing fresh data with stale history.
                let alpha = dt > 1 ? 1 : 1 - exp(-dt / 0.6)
                value = value.map { $0 + alpha * (incoming - $0) } ?? incoming
            } else { value = incoming }
            timestamp = date
            return value
        }
    }
}
