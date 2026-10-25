import Foundation

@main struct RecordingUploadDiagnosticsTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw BackendError.invalidInput("FAIL: " + message) }; checks += 1
    }
    static func main() throws {
        func diagnostic(_ failure: String? = nil, trace: TripUploadTrace? = nil, server: UUID? = nil, receipt: Bool = false, refusal: String? = nil, legacy: Bool = false, remote: Bool = true) -> RecordingUploadDiagnostics {
            .init(preflightFailure: failure, trace: trace, serverTripID: server, hasReceipt: receipt, serverReason: refusal, legacyAttemptUnknown: legacy, isRemote: remote)
        }
        try check(diagnostic("event_recording_incomplete").state == .notEligible, "local refusal is not an uploaded trip")
        try check(diagnostic().state == .ready && diagnostic().transport.contains("Local-only"), "eligible local trip still needs an explicit estimate request")
        var trace = TripUploadTrace(requestedAt: Date()); trace.stage = .vehicle
        try check(diagnostic(trace: trace).transport.contains("Local-only"), "vehicle PUT does not imply trip POST")
        trace.stage = .post; trace.postAttemptedAt = Date(); trace.postAttemptCount = 1
        try check(diagnostic(trace: trace).state == .attempted, "POST attempt does not prove acceptance")
        let server = UUID()
        try check(diagnostic(trace: trace, server: server).state == .accepted, "server acceptance alone is not a scored receipt")
        try check(diagnostic(trace: trace, server: server, refusal: "trip_not_scored").state == .notScored, "server refusal is distinct from local preflight")
        try check(diagnostic(server: server, receipt: true).state == .scored, "successful financial receipt means scored")
        try check(diagnostic("account changed", server: server, receipt: true).state == .scored, "known accepted receipt is not relabeled by later preflight changes")
        try check(diagnostic(server: server, receipt: true, remote: false).state == .offline, "mock receipt never claims backend scoring")
        try check(diagnostic(legacy: true).transport.contains("Unknown legacy"), "legacy missing attempt evidence remains unknown")
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        func gps(_ seconds: Double, speed: Double = 10, accuracy: Double = 1) -> APISpeedSample {
            .init(ts: clock.addingTimeInterval(seconds), sample_seq: Int(seconds * 100), speed_mps: speed, speed_accuracy_mps: accuracy)
        }
        var history = DetectorGPSHistory()
        let earlier = gps(0.5), newer = gps(1.5)
        history.observe(earlier); history.observe(newer)
        let delayedMotionTime = clock.addingTimeInterval(1.4)
        try check(GPSScoringWindow.freshSpeed(newer, at: delayedMotionTime) == nil, "reproduces newest-only GPS bug for delayed motion callbacks")
        try check(history.speed(at: delayedMotionTime) == 10 && history.observation(at: delayedMotionTime) == earlier, "actual earlier observation correctly supports delayed motion without future data")
        history.observe(gps(1.2, accuracy: 3))
        try check(history.speed(at: delayedMotionTime) == nil, "invalid newest-at-time observation is not concealed by older valid GPS")
        try check(history.speed(at: clock.addingTimeInterval(4.51)) == nil, "retained GPS never bypasses freshness")
        history.observe(gps(2.5, speed: 0))
        try check(history.speed(at: clock.addingTimeInterval(2.6)) == 0, "actual fresh red-light observation remains valid")
        try check(history.speed(at: clock) == nil, "future-only history cannot establish monitoring")
        history.observe(gps(30))
        try check(history.speed(at: delayedMotionTime) == nil, "pruned evidence remains unknown, never reconstructed")
        let fixture = try APIJSON.decoder().decode(APITripPayload.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/calculation-trip.json")))
        let begin = fixture.started_at.addingTimeInterval(-0.625), end = fixture.ended_at.addingTimeInterval(0.375)
        var coverage = DetectorCoverage(startedUptime: 100)
        coverage.observe(uptime: 100.1, eligible: false, reason: "No GPS speed observation available")
        coverage.observe(uptime: 100.7)
        coverage.observe(uptime: 102, eligible: false, reason: "GPS speed stale")
        coverage.invalidate("Mount angle changed")
        let details = RecordingDetails(endedAt: end, elapsedSeconds: 301, distanceAvailable: true, distanceIsPartial: false, motionAvailable: true, calibrationDescription: "Controlled fixture", events: [], motionSamples: [], gpsPoints: [], interruptions: ["Mount angle changed"], speedSamples: fixture.speed_samples, eventsComplete: false, detectorVersion: CandidateEventDetector.version, detectorCoverage: coverage, observedGPSWindowComplete: false)
        let trip = Trip(id: UUID(), title: "Offline diagnostic fixture", date: begin, distanceMiles: fixture.distance_mi, durationMinutes: 5, harshBraking: 0, rapidAcceleration: 0, mpg: 0, fuelPrice: 0, modeledExcessGallons: 0, source: .measured, recording: details, clientTripID: UUID())
        let report = diagnostic("event_recording_incomplete").summary(for: trip)
        try check(report.contains("301 total / 300 valid"), "valid GPS count distinguishes unavailable speed observations")
        try check(report.contains("leading edge: 0.625 s") && report.contains("trailing edge: 0.375 s"), "diagnostics use actual measurement edge gaps")
        try check(report.contains("Largest valid-speed GPS gap: 2.000 s"), "largest gap uses valid observations rather than callback count")
        try check(report.contains("Mount angle changed") && report.contains("GPS speed stale"), "actual saved interruption and eligibility reasons exposed")
        try check(report.contains("events_complete: false") && report.contains("detector_version: " + CandidateEventDetector.version), "metadata is displayed without changing completeness")
        try check(trip.recording?.eventsComplete == false && trip.recording?.speedSamples == fixture.speed_samples, "diagnostic projection never rewrites recorded evidence")
        let roundTrip = try JSONDecoder().decode(DetectorCoverage.self, from: JSONEncoder().encode(coverage))
        try check(roundTrip.runs?.first?.reason == "No GPS speed observation available", "monitoring reason persists")
        let legacyRuns = try JSONDecoder().decode(DetectorCoverage.self, from: Data("{\"startedUptime\":0,\"failures\":[],\"runs\":[{\"first\":0,\"last\":1,\"eligible\":false}]}".utf8))
        try check(legacyRuns.runs?.first?.reason == nil, "old monitoring runs decode without invented reasons")
        print("\(checks) recording upload diagnostic checks passed")
    }
}
