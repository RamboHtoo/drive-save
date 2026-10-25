// Synthetic observations, passed through the unmodified iOS TripUploadBuilder
// and APIJSON encoder. This is NOT a sensor capture or a real driving trip.
import Foundation

let start = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
let times: [Double] = [0, 30, 33, 60, 66, 80, 100, 120, 300]
let mph: [Double] = [34, 34, 12, 12, 45, 21, 21, 75, 75]
func speed(_ t: Double) -> Double {
    for i in 1..<times.count where t <= times[i] {
        let w = (t - times[i-1]) / (times[i] - times[i-1])
        return (mph[i-1] + w * (mph[i] - mph[i-1])) * 0.44704
    }
    return mph.last! * 0.44704
}
let samples = (0...300).map { i in
    APISpeedSample(ts: start.addingTimeInterval(Double(i) + 0.625),
                   sample_seq: i, speed_mps: speed(Double(i)), speed_accuracy_mps: 0.4)
}
let miles = (1...300).reduce(0.0) { total, i in
    total + (samples[i-1].speed_mps! + samples[i].speed_mps!) / 2 / 1609.344
}
let definitions: [(DrivingEventKind, Double, Double, Double)] = [
    (.harshBraking, 30, 3, 0.34), (.rapidAcceleration, 60, 6, 0.30), (.sharpTurn, 90, 4, 0.44)
]
let events = definitions.enumerated().map { i, value in
    DrivingEvent(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i + 1))!,
                 timestamp: start.addingTimeInterval(value.1 + 0.625), kind: value.0,
                 magnitude: value.3 * 9.80665, detectorVersion: "synthetic-ios-contract-v1",
                 durationSeconds: value.2, peakG: value.3)
}
let recording = RecordingDetails(endedAt: start.addingTimeInterval(301), elapsedSeconds: 301,
    distanceAvailable: true, distanceIsPartial: false, motionAvailable: true,
    calibrationDescription: "Synthetic contract test; no device calibration",
    events: events, motionSamples: [], gpsPoints: [], interruptions: [],
    measurementsIncomplete: false, speedSamples: samples)
let trip = Trip(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
    title: "Synthetic Swift GPS-window contract test", date: start, distanceMiles: miles,
    durationMinutes: 5, harshBraking: 1, rapidAcceleration: 1,
    mpg: 28, fuelPrice: 3.5, modeledExcessGallons: 0, source: .simulated,
    recording: recording, activity: .driving,
    clientTripID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!)
// Preserve the builder's real behavior, including its missing trip metadata.
let payload = try TripUploadBuilder.payload(for: trip)
FileHandle.standardOutput.write(try APIJSON.encoder().encode(payload))
