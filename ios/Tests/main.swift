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


var walkingFilter = GPSDistanceFilter(maximumSpeedMetersPerSecond: 12)
var walkingMeters = 0.0
for second in 0...10 {
    let update = walkingFilter.accept(point(Double(second), lat: 40 + Double(second)*0.00001), startedAt: date, now: date.addingTimeInterval(Double(second)))
    walkingMeters += update?.addedMeters ?? 0
}
check(walkingMeters > 9 && walkingMeters < 13, "small walking steps accumulate past noise threshold")
var walking = recorded
walking.activity = .walkingTest
check(walking.displayTitle == "Walking Test" && !walking.hasEstimate, "Walking Test label and no fuel estimate")
check(!walking.isCrewCandidate && [walking, recorded, demo].crewCandidates == [recorded], "Walking Tests and demos excluded from crew inputs")
check([walking, recorded, demo].drivingOnly == [recorded, demo], "Walking Tests excluded from driving history")
try store.save([walking, recorded])
let reloadedWalking = try store.load()
check(reloadedWalking.first == walking, "Walking Test provenance persists and reloads")
let payload = TripExportPayload(trip: walking)
let payloadData = try payload.jsonData()
let json = try JSONSerialization.jsonObject(with: payloadData) as! [String: Any]
check(json["activity"] as? String == "walkingTest" && json["excludedFromCrewScoring"] as? Bool == true, "export preserves walking and crew exclusion")
check(json["mpg"] == nil && json["fuelPrice"] == nil && json["modeledExcessGallons"] == nil, "Walking Test export omits fuel placeholders")
check(json["distanceMiles"] == nil && json["measurementsIncomplete"] as? Bool == true, "export omits unavailable distance instead of sending false zero")
check(json["startedAt"] is String, "export uses ISO 8601 timestamps")
var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recorded)) as! [String: Any]
legacy.removeValue(forKey: "activity")
let legacyData = try JSONSerialization.data(withJSONObject: legacy)
let legacyTrip = try JSONDecoder().decode(Trip.self, from: legacyData)
check(legacyTrip.isDriving, "legacy saved trips without activity still load as driving")

final class StubURLProtocol: URLProtocol {
    static var status = 200
    static var responseBody = Data()
    static var received: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.received = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

Task {
    do {
        let mock = APIClient(mode: .mock)
        let snapshot = try await mock.fetchSnapshot()
        check(snapshot.trips.count == DemoData.snapshot.trips.count, "mock snapshot remains isolated from network")
        if case .mockPreview(let preview) = try await mock.uploadTrip(walking) {
            check(!preview.isEmpty, "mock upload explicitly returns preview, not server success")
        } else { fatalError("Mock should never report remote upload") }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let configuration = APIClient.RemoteConfiguration(snapshotURL: URL(string: "https://example.invalid/team-confirmed-snapshot")!, tripUploadURL: URL(string: "https://example.invalid/team-confirmed-upload")!, snapshotMethod: "GET", tripUploadMethod: "POST", headers: ["X-Test": "fixture"], encodeTrip: { try TripExportPayload(trip: $0).jsonData() }, decodeSnapshot: { try JSONDecoder().decode(AppSnapshot.self, from: $0) })
        let remote = APIClient(mode: .remote(configuration), session: URLSession(configuration: sessionConfiguration))
        StubURLProtocol.responseBody = try JSONEncoder().encode(DemoData.snapshot)
        _ = try await remote.fetchSnapshot()
        check(StubURLProtocol.received?.url == configuration.snapshotURL, "remote mode uses supplied endpoint and response adapter")
        _ = try await remote.uploadTrip(walking)
        check(StubURLProtocol.received?.httpMethod == "POST" && StubURLProtocol.received?.value(forHTTPHeaderField: "X-Test") == "fixture", "remote upload uses supplied method, headers and payload adapter")
        StubURLProtocol.status = 503
        do { _ = try await remote.fetchSnapshot(); fatalError("Expected HTTP error") }
        catch APIClient.APIError.httpStatus(503) { print("PASS: remote HTTP error is surfaced") }
        print("All regression checks passed.")
        exit(0)
    } catch { print("FAIL: \(error)"); exit(1) }
}
dispatchMain()
