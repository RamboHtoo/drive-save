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
    let magnitude: Double // m/s²
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
            guard magnitude >= threshold else { starts[kind] = nil; continue }
            if starts[kind] == nil { starts[kind] = uptime }
            if uptime - (starts[kind] ?? uptime) >= configuration.minimumDuration,
               uptime - (lastEvents[kind] ?? -.infinity) >= configuration.cooldown {
                result.append(.init(timestamp: date, kind: kind, magnitude: magnitude))
                lastEvents[kind] = uptime
                starts[kind] = nil
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
    private var previous: GPSPoint?
    mutating func accept(_ point: GPSPoint, startedAt: Date, now: Date) -> Update? {
        let age = now.timeIntervalSince(point.timestamp)
        guard point.accuracyMeters.isFinite, (0...35).contains(point.accuracyMeters),
              point.latitude.isFinite, point.longitude.isFinite,
              (-90...90).contains(point.latitude), (-180...180).contains(point.longitude),
              (-2...10).contains(age), point.timestamp >= startedAt else { return nil }
        guard let previous else {
            self.previous = point
            return Update(addedMeters: 0, hasDistance: false, gap: false)
        }
        let dt = point.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return nil }
        let radians = Double.pi / 180
        let a = pow(sin((point.latitude-previous.latitude)*radians/2), 2)
            + cos(previous.latitude*radians)*cos(point.latitude*radians)
            * pow(sin((point.longitude-previous.longitude)*radians/2), 2)
        let meters = 6_371_000 * 2 * atan2(sqrt(max(0, min(1, a))), sqrt(max(0, 1-a)))
        guard meters / dt <= 65 else { return nil }
        self.previous = point
        let gap = dt > 10
        let noiseRadius = max(3, min(point.accuracyMeters, previous.accuracyMeters))
        return Update(addedMeters: !gap && meters >= noiseRadius ? meters : 0, hasDistance: true, gap: gap)
    }
}
