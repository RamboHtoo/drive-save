import Foundation

/// Offline fixture tests. These are serializer outputs, never physical driving evidence or uploads.
@main struct RecordingContractTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BackendError.invalidInput("FAIL: " + message) }
        checks += 1; print("PASS: " + message)
    }
    static func main() throws {
        let precise = Date(timeIntervalSince1970: 1792886460.123456)
        let preciseJSON = try APIJSON.encoder().encode(precise)
        let preciseRoundTrip = try APIJSON.decoder().decode(Date.self, from: preciseJSON)
        try check(String(decoding: preciseJSON, as: UTF8.self).contains(".123456Z"), "wire timestamps preserve observed microseconds rather than snapping to milliseconds")
        try check(abs(preciseRoundTrip.timeIntervalSince(precise)) < 0.000001, "microsecond sensor timestamps survive wire decoding within backend precision")
        var coverage = DetectorCoverage(startedUptime: 100)
        try check(!coverage.complete(through: 101), "no observations never means complete")
        coverage.observe(uptime: 100.1); coverage.observe(uptime: 101)
        try check(!coverage.complete(through: 101), "startup gap stays incomplete")
        var complete = DetectorCoverage(startedUptime: 100)
        for i in 0...10 { complete.observe(uptime: 100 + Double(i) / 10) }
        try check(complete.complete(through: 101), "explicit observations spanning the interval can be complete")
        try check(!complete.complete(through: 101.1), "shutdown gap stays incomplete")
        complete.observe(uptime: 103)
        try check(!complete.complete(through: 103), "motion gap permanently invalidates completeness")
        var paused = DetectorCoverage(startedUptime: 0)
        paused.observe(uptime: 0); paused.invalidate("GPS speed unavailable"); paused.observe(uptime: 1)
        try check(!paused.complete(through: 1), "GPS/detector pause cannot become complete later")
        let fixture = try APIJSON.decoder().decode(APITripPayload.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/calculation-trip.json")))
        let row = try APIJSON.decoder().decode(VehicleRow.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/catalog-mazda5.json")))
        let owner = UUID()
        let context = RecordingContext(ownerID: owner, accountScope: "https://example.invalid", vehicle: row, vehicleConfirmed: true)
        try context.validate(ownerID: owner, accountScope: context.accountScope)
        for (otherOwner, scope) in [(UUID(), context.accountScope), (owner, "mock")] {
            do { try context.validate(ownerID: otherOwner, accountScope: scope); throw NSError(domain: "Expected rejection", code: 1) }
            catch BackendError.invalidInput { try check(true, "account or server changes reject the frozen recording identity") }
        }
        var details = RecordingDetails(endedAt: fixture.ended_at, elapsedSeconds: fixture.ended_at.timeIntervalSince(fixture.started_at), distanceAvailable: true, distanceIsPartial: false, motionAvailable: true, calibrationDescription: "Offline synthetic sensor fixture; not a physical recording", events: [], motionSamples: [], gpsPoints: [], interruptions: [], measurementsIncomplete: false, speedSamples: fixture.speed_samples)
        var trip = Trip(id: UUID(), title: "Offline serializer fixture", date: fixture.started_at, distanceMiles: fixture.distance_mi, durationMinutes: 5, harshBraking: 0, rapidAcceleration: 0, mpg: 0, fuelPrice: 0, modeledExcessGallons: 0, source: .simulated, recording: details, clientTripID: UUID(), recordingContext: context)
        let legacy = try TripUploadBuilder.payload(for: trip)
        try check(legacy.events_complete == false && legacy.detector_version == nil, "legacy detector metadata is unknown, never invented")
        try check(TripUploadBuilder.scoringIssue(for: trip)?.contains("event_recording_incomplete") == true, "empty events without coverage are insufficient")
        details.eventsComplete = true; details.detectorVersion = CandidateEventDetector.version
        trip.recording = details
        let payload = try TripUploadBuilder.payload(for: trip)
        try check(payload.events_complete == true && payload.detector_version == CandidateEventDetector.version, "persisted completeness and session version reach wire JSON even without events")
        try check(TripUploadBuilder.scoringIssue(for: trip) == nil, "contract-conformant fixture is eligible for backend validation")
        let persisted = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        try check(persisted == trip && persisted.recordingContext?.vehicle == row, "owner, complete EPA vehicle and detector evidence survive local persistence exactly")
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/drivesave-recording-contract")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try APIJSON.encoder().encode(TripUploadBuilder.payload(for: persisted)).write(to: output.appendingPathComponent("complete-fixture.json"))
        // Controlled fixture models a button tap preceding the first observation. GPS values/times are untouched.
        let boundaryTrip = Trip(id: UUID(), title: "Offline boundary-gap fixture", date: fixture.started_at.addingTimeInterval(-0.1), distanceMiles: fixture.distance_mi, durationMinutes: 5, harshBraking: 0, rapidAcceleration: 0, mpg: 0, fuelPrice: 0, modeledExcessGallons: 0, source: .simulated, recording: details, clientTripID: UUID(), recordingContext: context)
        try check(TripUploadBuilder.scoringIssue(for: boundaryTrip)?.contains("missing_boundary_speed") == true, "button-tap boundary is rejected rather than snapped to GPS")
        let boundary = try TripUploadBuilder.payload(for: boundaryTrip)
        try check(boundary.started_at == boundaryTrip.date && boundary.speed_samples == fixture.speed_samples, "serialization preserves raw GPS and interval timestamps")
        try APIJSON.encoder().encode(boundary).write(to: output.appendingPathComponent("boundary-gap-fixture.json"))
        let recordedModeFixture = Trip(id: UUID(), title: "Offline recorded-mode serializer fixture (not a physical drive)", date: boundaryTrip.date, distanceMiles: fixture.distance_mi, durationMinutes: 5, harshBraking: 0, rapidAcceleration: 0, mpg: 0, fuelPrice: 0, modeledExcessGallons: 0, source: .measured, recording: details, clientTripID: UUID(), recordingContext: context)
        let recordedPayload = try TripUploadBuilder.payload(for: recordedModeFixture)
        try check(recordedPayload.source == "recorded" && !recordedPayload.is_demo, "recorded-mode serializer preserves genuine provenance; backend experimental policy stays server-side")
        try APIJSON.encoder().encode(recordedPayload).write(to: output.appendingPathComponent("recorded-mode-fixture.json"))
        details.eventsComplete = false; trip.recording = details
        try APIJSON.encoder().encode(TripUploadBuilder.payload(for: trip)).write(to: output.appendingPathComponent("incomplete-fixture.json"))
        details.detectorVersion = nil; details.eventsComplete = nil; trip.recording = details
        let legacyTrip = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        try check(legacyTrip.recording?.eventsComplete == nil, "old saved recordings retain unknown completeness after decoding")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as! [String: Any]
        oldJSON.removeValue(forKey: "recordingContext")
        let oldTrip = try JSONDecoder().decode(Trip.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try check(oldTrip.recordingContext == nil, "legacy history remains decodable without assigning today's owner or vehicle")
        details.eventsComplete = true; trip.recording = details
        try check(TripUploadBuilder.scoringIssue(for: trip) == "missing_detector_version", "complete flag cannot conceal a missing detector version")
        details.detectorVersion = CandidateEventDetector.version
        details = RecordingDetails(endedAt: details.endedAt, elapsedSeconds: details.elapsedSeconds, distanceAvailable: true, distanceIsPartial: false, motionAvailable: true, calibrationDescription: "Fixture", events: [.init(timestamp: trip.date.addingTimeInterval(30), kind: .rapidAcceleration, magnitude: 3, detectorVersion: "other-version", durationSeconds: 1, peakG: 0.3)], motionSamples: [], gpsPoints: [], interruptions: [], speedSamples: fixture.speed_samples, eventsComplete: true, detectorVersion: CandidateEventDetector.version)
        trip.recording = details
        try check(TripUploadBuilder.scoringIssue(for: trip) == "detector_version_mismatch", "mixed detector versions cannot be scored as a complete session")
        print("\(checks) recording contract checks passed. Swift-generated fixture payloads: \(output.path)")
    }
}
