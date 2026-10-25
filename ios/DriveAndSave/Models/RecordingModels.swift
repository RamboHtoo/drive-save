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

/// vehicle-fuel-v2 / observed-gps-window-v1. Uses measurement times, never button-time copies.
struct GPSScoringWindow {
    let first: Date
    let last: Date
    static func valid(_ sample: APISpeedSample) -> Bool {
        guard let speed = sample.speed_mps, let accuracy = sample.speed_accuracy_mps else { return false }
        return speed.isFinite && (0...53.6448).contains(speed) && accuracy.isFinite && (0...2).contains(accuracy)
    }
    static func freshSpeed(_ sample: APISpeedSample?, at time: Date) -> Double? {
        guard let sample, valid(sample), (0...3).contains(time.timeIntervalSince(sample.ts)) else { return nil }
        return sample.speed_mps
    }
    init(samples: [APISpeedSample], startedAt: Date, endedAt: Date) throws {
        guard endedAt > startedAt, samples.allSatisfy({ $0.ts.timeIntervalSince1970.isFinite && $0.ts >= startedAt && $0.ts <= endedAt }) else {
            throw BackendError.invalidInput("out_of_trip_timestamp: Every GPS observation must remain inside the original recording interval.")
        }
        let valid = samples.filter(Self.valid).sorted { $0.ts < $1.ts }
        guard valid.count >= 2, let first = valid.first?.ts, let last = valid.last?.ts, last > first else {
            throw BackendError.invalidInput("insufficient_valid_speed: At least two distinct GPS observations need speed 0–53.6448 m/s and speed accuracy 0–2 m/s.")
        }
        guard first.timeIntervalSince(startedAt) <= 3.000001, endedAt.timeIntervalSince(last) <= 3.000001 else {
            throw BackendError.invalidInput("gps_boundary_gap_over_three_seconds: The first and last valid GPS observations must be within 3 seconds of Start and Stop. Original timestamps are retained.")
        }
        self.first = first; self.last = last
    }
}

/// Real recent observations, retained for asynchronous GPS/IMU callback ordering.
/// Select by measurement time, never replace or shift a reading to cover a motion timestamp.
struct DetectorGPSHistory {
    private var samples: [APISpeedSample] = []
    mutating func observe(_ sample: APISpeedSample) {
        guard sample.ts.timeIntervalSince1970.isFinite else { return }
        samples.append(sample)
        samples.sort { $0.ts < $1.ts }
        if let latest = samples.last?.ts {
            samples.removeAll { latest.timeIntervalSince($0.ts) > 10 }
        }
        if samples.count > 128 { samples.removeFirst(samples.count - 128) }
    }
    func observation(at time: Date) -> APISpeedSample? {
        samples.last { $0.ts <= time }
    }
    func speed(at time: Date) -> Double? {
        GPSScoringWindow.freshSpeed(observation(at: time), at: time)
    }
}

struct GPSQualitySummary: Codable, Hashable {
    let startupSeconds: Double?
    let trailingSeconds: Double?
    let maximumGapSeconds: Double
    var isPartial: Bool { (startupSeconds ?? 0) > 3.000001 || (trailingSeconds ?? 0) > 3.000001 || maximumGapSeconds > 3.000001 }
}

/// Only reliable measurement timestamps establish coverage. Callback errors alone do not.
struct GPSQualityTracker {
    let startedAt: Date
    private var first: Date?
    private var last: Date?
    private var maximumGap = 0.0
    mutating func observe(_ timestamp: Date) {
        guard timestamp >= startedAt, timestamp.timeIntervalSince1970.isFinite else { return }
        if let last {
            guard timestamp > last else { return }
            maximumGap = max(maximumGap, timestamp.timeIntervalSince(last))
        }
        if first == nil { first = timestamp }
        last = timestamp
    }
    func summary(through end: Date) -> GPSQualitySummary {
        .init(startupSeconds: first.map { $0.timeIntervalSince(startedAt) }, trailingSeconds: last.map { max(0, end.timeIntervalSince($0)) }, maximumGapSeconds: maximumGap)
    }
}

/// Frozen locally at Start; never contains authentication secrets.
struct RecordingContext: Codable, Hashable {
    let ownerID: UUID
    let accountScope: String
    let vehicle: VehicleRow?
    let vehicleConfirmed: Bool

    func validate(ownerID: UUID?, accountScope: String) throws {
        guard self.ownerID == ownerID, self.accountScope == accountScope else {
            throw BackendError.invalidInput("This recording belongs to a different account or server. Sign in to its original account to upload it.")
        }
    }
}

/// Actual motion observations and their classification eligibility, independent of button edges.
struct DetectorCoverage: Codable, Hashable {
    struct Run: Codable, Hashable {
        let first: Double
        var last: Double
        let eligible: Bool
        var reason: String? = nil
    }
    let startedUptime: Double
    private(set) var firstObservation: Double?
    private(set) var lastObservation: Double?
    private(set) var failures: [String] = []
    private(set) var runs: [Run]? = nil // nil in legacy archives: never invent coverage.

    mutating func invalidate(_ reason: String) {
        if !failures.contains(reason) { failures.append(reason) }
    }
    mutating func observe(uptime: Double, eligible: Bool = true, reason: String? = nil) {
        guard uptime.isFinite, uptime >= startedUptime else { return }
        if let lastObservation, uptime <= lastObservation { invalidate("Non-monotonic detector samples"); return }
        if firstObservation == nil { firstObservation = uptime }
        if runs == nil { runs = [] }
        if let previous = runs?.last, previous.eligible == eligible, previous.reason == reason, uptime - previous.last <= 1 {
            runs![runs!.count - 1].last = uptime
        } else { runs?.append(.init(first: uptime, last: uptime, eligible: eligible, reason: reason)) }
        lastObservation = uptime
    }
    func complete(from start: Double, through end: Double) -> Bool {
        guard start.isFinite, end.isFinite, end > start, failures.isEmpty,
              let firstObservation, let lastObservation, firstObservation <= start, lastObservation >= end,
              let runs, !runs.isEmpty else { return false }
        for run in runs where !run.eligible && run.last >= start && run.first <= end { return false }
        for (left, right) in zip(runs, runs.dropFirst()) {
            if right.first - left.last > 1, left.last < end, right.first > start { return false }
        }
        return true
    }
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
    var eventsComplete: Bool? = nil
    var detectorVersion: String? = nil
    var detectorCoverage: DetectorCoverage? = nil
    var observedGPSWindowComplete: Bool? = nil
    var gpsQuality: GPSQualitySummary? = nil
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
    static let version = "ios-0.3.1"
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
                result.append(.init(timestamp: date.addingTimeInterval(-duration), kind: kind, magnitude: peak, detectorVersion: Self.version, durationSeconds: duration, peakG: peak / 9.80665))
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
        let gap = dt > 3.000001
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
