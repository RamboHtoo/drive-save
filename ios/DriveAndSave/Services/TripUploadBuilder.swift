import Foundation

enum TripUploadBuilder {
    static func payload(for trip: Trip) throws -> APITripPayload {
        guard !trip.isWalkingTest else { throw BackendError.invalidInput("Walking Tests cannot be uploaded to the driving API.") }
        guard let clientID = trip.clientTripID, let recording = trip.recording else { throw BackendError.invalidInput("This older trip lacks a recording-start client ID. Record a new trip or use Test Calculation in Developer Mode.") }
        guard let samples = recording.speedSamples else { throw BackendError.invalidInput("This older recording has no timestamped GPS speed accuracy/sequence data. Upload is unsupported.") }
        var events: [APITripEvent] = []
        for event in recording.events {
            guard let version = event.detectorVersion, let duration = event.durationSeconds, let peak = event.peakG else { throw BackendError.invalidInput("An event lacks detector version, observed duration, or peak acceleration. No values were fabricated.") }
            let before = samples.filter { $0.ts <= event.timestamp && event.timestamp.timeIntervalSince($0.ts) <= 10 && GPSScoringWindow.valid($0) }.max { $0.ts < $1.ts }
            let end = event.timestamp.addingTimeInterval(duration)
            let after = samples.filter { $0.ts >= end && $0.ts.timeIntervalSince(end) <= 10 && GPSScoringWindow.valid($0) }.min { $0.ts < $1.ts }
            guard let beforeSpeed = before?.speed_mps, let afterSpeed = after?.speed_mps else { throw BackendError.invalidInput("Event \(event.kind.label) lacks valid before/after GPS speed readings. Keep the trip locally; it cannot be priced reliably.") }
            let courseBefore = recording.gpsPoints.filter { $0.timestamp <= event.timestamp && event.timestamp.timeIntervalSince($0.timestamp) <= 10 && $0.courseDegrees != nil }.last?.courseDegrees
            let courseAfter = recording.gpsPoints.first { $0.timestamp >= end && $0.timestamp.timeIntervalSince(end) <= 10 && $0.courseDegrees != nil }?.courseDegrees
            var heading: Double?
            if event.kind == .sharpTurn, let a = courseBefore, let b = courseAfter { let diff = abs(a-b).truncatingRemainder(dividingBy: 360); heading = min(diff, 360-diff) }
            let kind: String
            switch event.kind { case .harshBraking: kind = "harsh_brake"; case .rapidAcceleration: kind = "rapid_accel"; case .sharpTurn: kind = "sharp_turn" }
            events.append(.init(event_id: event.id, type: kind, ts: event.timestamp, detector_version: version, peak_g: peak, speed_before_mph: beforeSpeed * 2.2369362921, speed_after_mph: afterSpeed * 2.2369362921, duration_s: duration, heading_change_deg: heading))
        }
        let duration = recording.endedAt.timeIntervalSince(trip.date)
        let result = APITripPayload(client_trip_id: clientID, started_at: trip.date, ended_at: recording.endedAt, distance_mi: trip.distanceMiles, avg_speed_mph: trip.distanceMiles / (duration / 3600), source: trip.source == .simulated ? "replayed" : "recorded", is_demo: trip.source == .simulated, events: events, speed_samples: samples, events_complete: recording.eventsComplete ?? false, detector_version: recording.detectorVersion)
        try validate(result)
        return result
    }
    /// Local edge/metadata checks only; the server owns detailed coverage, gaps and physics gates.
    static func scoringIssue(for trip: Trip) -> String? {
        guard let recording = trip.recording else { return "Missing recording details" }
        do { _ = try GPSScoringWindow(samples: recording.speedSamples ?? [], startedAt: trip.date, endedAt: recording.endedAt) }
        catch { return error.localizedDescription }
        guard recording.eventsComplete == true else { return "event_recording_incomplete: Detector coverage does not span the entire scoring interval (or is unknown for an older recording)." }
        guard let version = recording.detectorVersion, !version.isEmpty else { return "missing_detector_version" }
        guard recording.events.allSatisfy({ $0.detectorVersion == version }) else { return "detector_version_mismatch" }
        return nil
    }
    static func validate(_ payload: APITripPayload) throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw BackendError.invalidInput(message) } }
        try require(payload.started_at.timeIntervalSince1970.isFinite && payload.ended_at.timeIntervalSince1970.isFinite, "Trip timestamps must be finite.")
        try require(payload.ended_at > payload.started_at, "Trip end must be after its start.")
        try require(payload.distance_mi.isFinite && payload.distance_mi > 0 && payload.distance_mi <= 1000, "Trip distance must be in (0, 1000] miles.")
        try require(payload.avg_speed_mph.isFinite && (0...120).contains(payload.avg_speed_mph), "Average speed must be between 0 and 120 mph.")
        try require(["recorded", "replayed", "synthetic"].contains(payload.source) && (payload.source == "recorded" || payload.is_demo), "Replay/synthetic trips must be marked demo.")
        try require(payload.speed_samples.count <= 21_600, "Too many speed samples; upload is unsupported.")
        try require(Set(payload.events.map(\.event_id)).count == payload.events.count, "Duplicate event IDs.")
        try require(Set(payload.speed_samples.map(\.sample_seq)).count == payload.speed_samples.count, "Duplicate speed sample sequence values.")
        let maxEvents = max(payload.ended_at.timeIntervalSince(payload.started_at) / 60, 1) * 10
        try require(Double(payload.events.count) <= maxEvents, "More than 10 candidate events per minute; this recording needs review.")
        for sample in payload.speed_samples {
            try require(sample.sample_seq >= 0 && sample.ts >= payload.started_at && sample.ts <= payload.ended_at, "Speed sample is outside the trip window or has an invalid sequence.")
            if let speed = sample.speed_mps { try require(speed.isFinite && (0...53.6448).contains(speed), "Invalid GPS speed.") }
            if let accuracy = sample.speed_accuracy_mps { try require(accuracy.isFinite && accuracy >= 0, "Invalid GPS speed accuracy.") }
        }
        if !payload.events.isEmpty { try require(payload.speed_samples.contains { GPSScoringWindow.valid($0) }, "Events require valid GPS speed samples.") }
        for event in payload.events {
            try require(["harsh_brake", "rapid_accel", "sharp_turn"].contains(event.type) && !event.detector_version.isEmpty && event.detector_version.count <= 64, "Unsupported event type or detector version.")
            try require(event.ts >= payload.started_at && event.ts <= payload.ended_at, "Event is outside the trip window.")
            try require(event.peak_g.isFinite && event.peak_g > 0 && event.peak_g <= 2, "Event peak must be within (0, 2] g.")
            for speed in [event.speed_before_mph, event.speed_after_mph] { try require(speed.isFinite && (0...120).contains(speed), "Event speeds must be between 0 and 120 mph.") }
            if let duration = event.duration_s { try require(duration.isFinite && duration > 0 && duration <= 60, "Event duration must be within (0, 60] seconds.") }
            if let heading = event.heading_change_deg { try require(heading.isFinite && (0...360).contains(heading), "Invalid heading change.") }
        }
        _ = try APIJSON.encoder().encode(payload) // JSONEncoder rejects any remaining non-finite numbers.
    }
}
