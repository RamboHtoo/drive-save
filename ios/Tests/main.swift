import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
    print("PASS: \(message)")
}

var detector = CandidateEventDetector()
let date = Date()
check(detector.update(forward: 4, lateral: 0, uptime: 0, date: date).isEmpty, "spike does not trigger an event")
check(detector.update(forward: 4, lateral: 0, uptime: 0.4, date: date).isEmpty, "minimum duration enforced")
check(detector.update(forward: 4, lateral: 0, uptime: 0.6, date: date).map(\.kind) == [.rapidAcceleration], "sustained acceleration detected")
check(detector.update(forward: 4, lateral: 0, uptime: 1.5, date: date).isEmpty, "cooldown prevents duplicate events")
_ = detector.update(forward: 0, lateral: 0, uptime: 2, date: date)
_ = detector.update(forward: -4, lateral: 4, uptime: 3, date: date)
let kinds = Set(detector.update(forward: -4, lateral: 4, uptime: 3.6, date: date).map(\.kind))
check(kinds == [.harshBraking, .sharpTurn], "braking and cornering candidates detected independently")
_ = detector.update(forward: 4, lateral: 0, uptime: 5, date: date)
check(detector.update(forward: 4, lateral: 0, uptime: 5.6, date: date).contains { $0.kind == .rapidAcceleration }, "detection resumes after cooldown")

let demo = DemoData.snapshot.trips[0]
let demoData = try JSONEncoder().encode(demo)
let decodedDemo = try JSONDecoder().decode(Trip.self, from: demoData)
check(decodedDemo == demo, "existing demo Codable model round-trips")
let details = RecordingDetails(endedAt: date, elapsedSeconds: 17, distanceAvailable: false, distanceIsPartial: true, motionAvailable: false, calibrationDescription: "Test", events: [], motionSamples: [], gpsPoints: [], interruptions: ["Permission denied"])
let recorded = Trip(id: UUID(), title: "Unit test drive", date: date, distanceMiles: 0, durationMinutes: 0, harshBraking: 0, rapidAcceleration: 0, mpg: 28, fuelPrice: 3.65, modeledExcessGallons: 0, source: .measured, recording: details)
check(!recorded.hasEstimate && recorded.distanceLabel == "Unavailable", "denied GPS and pending estimate do not appear as measured zeros")
check(recorded.durationLabel == "0:17", "sub-minute trips preserve exact duration")
let store = TripStore(fileURL: URL(fileURLWithPath: "/tmp/drive-save-model-tests/trips.json"))
try store.save([recorded])
let loaded = try store.load()
check(loaded == [recorded], "recorded trip persists and reloads with provenance and timestamps")
let corruptURL = URL(fileURLWithPath: "/tmp/drive-save-model-tests/corrupt.json")
try Data("invalid".utf8).write(to: corruptURL)
do { _ = try TripStore(fileURL: corruptURL).load(); fatalError("Expected corrupt store failure") }
catch { print("PASS: corrupted storage reports an error") }
print("All model tests passed.")

var gpsFilter = GPSDistanceFilter()
func point(_ seconds: Double, lat: Double = 40, accuracy: Double = 5) -> GPSPoint {
    GPSPoint(timestamp: date.addingTimeInterval(seconds), latitude: lat, longitude: -77, accuracyMeters: accuracy, speedMetersPerSecond: 10)
}
check(gpsFilter.accept(point(0, accuracy: 100), startedAt: date, now: date) == nil, "inaccurate GPS point rejected")
check(gpsFilter.accept(point(-20), startedAt: date, now: date) == nil, "old GPS point rejected")
check(gpsFilter.accept(point(0), startedAt: date, now: date)?.hasDistance == false, "first GPS fix alone does not establish distance")
check(gpsFilter.accept(point(0), startedAt: date, now: date) == nil, "duplicate timestamp rejected")
check(gpsFilter.accept(point(1, lat: 41), startedAt: date, now: date.addingTimeInterval(1)) == nil, "implausible location jump rejected")
let validGPS = gpsFilter.accept(point(2, lat: 40.0002), startedAt: date, now: date.addingTimeInterval(2))
check((validGPS?.addedMeters ?? 0) > 20 && (validGPS?.addedMeters ?? 0) < 24, "valid movement accumulates GPS distance")
let stationary = gpsFilter.accept(point(3, lat: 40.000201), startedAt: date, now: date.addingTimeInterval(3))
check(stationary?.addedMeters == 0 && stationary?.hasDistance == true, "stationary GPS drift does not inflate distance")
let gap = gpsFilter.accept(point(20, lat: 40.001), startedAt: date, now: date.addingTimeInterval(20))
check(gap?.gap == true && gap?.addedMeters == 0, "GPS gaps are flagged and not interpolated")
