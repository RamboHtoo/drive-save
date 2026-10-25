import Foundation

@main struct SampleTripReceiptTests {
    static func main() throws {
        let payload = try APIJSON.decoder().decode(APITripPayload.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/calculation-trip.json")))
        let details = RecordingDetails(endedAt: payload.ended_at, elapsedSeconds: 327, distanceAvailable: true, distanceIsPartial: false, motionAvailable: true, calibrationDescription: "Original fixture", events: [], motionSamples: [], gpsPoints: [], interruptions: [], speedSamples: payload.speed_samples, eventsComplete: true, detectorVersion: "ios-0.3.1")
        let originalVehicle: VehicleRow = ["make": .string("Original"), "model": .string("Unchanged")]
        let context = RecordingContext(ownerID: UUID(), accountScope: "isolated-test", vehicle: originalVehicle, vehicleConfirmed: true)
        var trip = Trip(id: UUID(), title: "Original recorded fixture", date: payload.started_at, distanceMiles: payload.distance_mi, durationMinutes: 5, harshBraking: 0, rapidAcceleration: 0, mpg: 0, fuelPrice: 0, modeledExcessGallons: 0, source: .measured, recording: details, clientTripID: UUID(), recordingContext: context)
        let before = try APIJSON.encoder().encode(trip)
        let uploadBefore = try APIJSON.encoder().encode(TripUploadBuilder.payload(for: trip))
        let eligibilityBefore = TripUploadBuilder.scoringIssue(for: trip)
        let preview = SampleTripReceipt(trip: trip)
        precondition(SampleTripReceipt.isAvailable(for: trip))
        precondition(preview.distance == trip.distanceLabel && preview.duration == "5:27" && preview.recordedDate == trip.date)
        precondition(SampleTripReceipt.vehicle == "2012 Mazda MAZDA5")
        precondition(SampleTripReceipt.vehicleDetails.count == 9)
        precondition(SampleTripReceipt.lines.map(\.label) == ["Acceleration", "Braking", "Turning", "High-speed driving"])
        precondition(SampleTripReceipt.lines.reduce(0) { $0 + $1.cents } == 42 && SampleTripReceipt.total == "$0.42")
        let after = try APIJSON.encoder().encode(trip)
        let uploadAfter = try APIJSON.encoder().encode(TripUploadBuilder.payload(for: trip))
        precondition(before == after && uploadBefore == uploadAfter)
        precondition(trip.recordingContext?.vehicle == originalVehicle && TripUploadBuilder.scoringIssue(for: trip) == eligibilityBefore)
        trip.recording = RecordingDetails(endedAt: details.endedAt, elapsedSeconds: details.elapsedSeconds, distanceAvailable: false, distanceIsPartial: true, motionAvailable: false, calibrationDescription: details.calibrationDescription, events: [], motionSamples: [], gpsPoints: [], interruptions: [])
        let incomplete = SampleTripReceipt(trip: trip)
        precondition(incomplete.distance == "Unavailable" && incomplete.partialDistance && incomplete.incompleteMeasurements)
        trip.activity = .walkingTest
        precondition(!SampleTripReceipt.isAvailable(for: trip))
        print("10 sample receipt checks passed: recorded values, illustrative total, original snapshot/sensors/payload/eligibility unchanged.")
    }
}
