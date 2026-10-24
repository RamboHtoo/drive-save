import Foundation

struct Vector3: Codable, Hashable {
    var x: Double; var y: Double; var z: Double
    static let zero = Vector3(x: 0, y: 0, z: 0)
    static func + (a: Self, b: Self) -> Self { .init(x: a.x+b.x, y: a.y+b.y, z: a.z+b.z) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x-b.x, y: a.y-b.y, z: a.z-b.z) }
    static func * (a: Self, b: Double) -> Self { .init(x: a.x*b, y: a.y*b, z: a.z*b) }
    func dot(_ b: Self) -> Double { x*b.x + y*b.y + z*b.z }
    var length: Double { sqrt(dot(self)) }
    var normalized: Self { self * (1 / max(length, 0.0001)) }
}

struct MotionSample: Codable, Hashable {
    let timestamp: Date
    let uptime: Double
    let userAcceleration: Vector3 // Core Motion units: g, phone coordinates
    let rotationRate: Vector3 // radians/second, phone coordinates
    let attitude: Vector3 // roll, pitch, yaw in radians
    let forwardAcceleration: Double? // m/s², calibrated reference frame
    let lateralAcceleration: Double? // m/s², calibrated reference frame
}

struct GPSPoint: Codable, Hashable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let speedMetersPerSecond: Double?
    var courseDegrees: Double? = nil
}

enum DrivingEventKind: String, Codable, CaseIterable {
    case harshBraking, rapidAcceleration, sharpTurn
    var label: String {
        switch self {
        case .harshBraking: return "Possible harsh braking"
        case .rapidAcceleration: return "Possible rapid acceleration"
        case .sharpTurn: return "Possible sharp turn"
        }
    }
}

struct DrivingEvent: Codable, Hashable, Identifiable {
    var id = UUID()
    let timestamp: Date
    let kind: DrivingEventKind
    let magnitude: Double // m/s², peak over the observed candidate window
    var detectorVersion: String? = nil
    var durationSeconds: Double? = nil
    var peakG: Double? = nil
}

struct RecordingDetails: Codable, Hashable {
    let endedAt: Date
    let elapsedSeconds: Double
    let distanceAvailable: Bool
    let distanceIsPartial: Bool
    let motionAvailable: Bool
    let calibrationDescription: String
    let events: [DrivingEvent]
    let motionSamples: [MotionSample]
    let gpsPoints: [GPSPoint]
    let interruptions: [String]
    var gpsAccuracyMeters: Double? = nil
    var detectionStatus: String? = nil
    var calibrationValidAtEnd: Bool? = nil
    var measurementsIncomplete: Bool? = nil
    var speedSamples: [APISpeedSample]? = nil
}

struct DetectionConfiguration: Codable, Hashable {
    var brakingThreshold = 2.8
    var accelerationThreshold = 2.5
    var corneringThreshold = 2.8
    var minimumDuration = 0.5
    var cooldown = 4.0
    var smoothingWeight = 0.25
}

/// Candidate detection only; thresholds require real-device validation.
struct CandidateEventDetector {
    var configuration = DetectionConfiguration()
    private var starts: [DrivingEventKind: Double] = [:]
    private var peaks: [DrivingEventKind: Double] = [:]
    private var lastEvents: [DrivingEventKind: Double] = [:]
    mutating func update(forward: Double, lateral: Double, uptime: Double, date: Date) -> [DrivingEvent] {
        let magnitudes: [DrivingEventKind: Double] = [.harshBraking: -forward, .rapidAcceleration: forward, .sharpTurn: abs(lateral)]
        var result: [DrivingEvent] = []
        for kind in DrivingEventKind.allCases {
            let threshold: Double
            switch kind {
            case .harshBraking: threshold = configuration.brakingThreshold
            case .rapidAcceleration: threshold = configuration.accelerationThreshold
            case .sharpTurn: threshold = configuration.corneringThreshold
            }
            let magnitude = magnitudes[kind] ?? 0
            guard magnitude >= threshold else { starts[kind] = nil; peaks[kind] = nil; continue }
            if starts[kind] == nil { starts[kind] = uptime }
            peaks[kind] = max(peaks[kind] ?? 0, magnitude)
            if uptime - (starts[kind] ?? uptime) >= configuration.minimumDuration,
               uptime - (lastEvents[kind] ?? -.infinity) >= configuration.cooldown {
                let duration = uptime - (starts[kind] ?? uptime)
                let peak = peaks[kind] ?? magnitude
                result.append(.init(timestamp: date.addingTimeInterval(-duration), kind: kind, magnitude: peak, detectorVersion: "ios-0.2.0", durationSeconds: duration, peakG: peak / 9.80665))
                lastEvents[kind] = uptime
                starts[kind] = nil
                peaks[kind] = nil
            }
        }
        return result
    }
}

/// Pure GPS validation/distance logic, shared by device recording and regression tests.
struct GPSDistanceFilter {
    struct Update {
        let addedMeters: Double
        let hasDistance: Bool
        let gap: Bool
    }
    // Accumulate walking movement against an anchor instead of dropping each small step.
    var maximumSpeedMetersPerSecond = 65.0
    private var previous: GPSPoint?
    private var distanceAnchor: GPSPoint?
    mutating func accept(_ point: GPSPoint, startedAt: Date, now: Date) -> Update? {
        let age = now.timeIntervalSince(point.timestamp)
        guard point.accuracyMeters.isFinite, (0...35).contains(point.accuracyMeters),
              point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude), (-180...180).contains(point.longitude),
              (-2...10).contains(age), point.timestamp >= startedAt else { return nil }
        guard let previous else {
            self.previous = point
            distanceAnchor = point
            return Update(addedMeters: 0, hasDistance: false, gap: false)
        }
        let dt = point.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return nil }
        let radians = Double.pi / 180
        let a = pow(sin((point.latitude-previous.latitude)*radians/2), 2)
            + cos(previous.latitude*radians)*cos(point.latitude*radians)
            * pow(sin((point.longitude-previous.longitude)*radians/2), 2)
        let meters = 6_371_000 * 2 * atan2(sqrt(max(0, min(1, a))), sqrt(max(0, 1-a)))
        guard meters / dt <= maximumSpeedMetersPerSecond else { return nil }
        self.previous = point
        let gap = dt > 10
        let noiseRadius = max(3, min(point.accuracyMeters, previous.accuracyMeters))
        if gap {
            distanceAnchor = point
            return Update(addedMeters: 0, hasDistance: true, gap: true)
        }
        let anchor = distanceAnchor ?? previous
        let anchorA = pow(sin((point.latitude-anchor.latitude)*radians/2), 2)
            + cos(anchor.latitude*radians)*cos(point.latitude*radians)
            * pow(sin((point.longitude-anchor.longitude)*radians/2), 2)
        let anchorMeters = 6_371_000 * 2 * atan2(sqrt(max(0, min(1, anchorA))), sqrt(max(0, 1-anchorA)))
        let added = anchorMeters >= noiseRadius ? anchorMeters : 0
        if added > 0 { distanceAnchor = point }
        return Update(addedMeters: added, hasDistance: true, gap: false)
    }
}
