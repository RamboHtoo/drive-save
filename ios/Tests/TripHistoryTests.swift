import Foundation
import SwiftUI

private final class HistoryNetworkSpy: URLProtocol {
    static var methods: [String] = []
    static var response = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.methods.append(request.httpMethod ?? "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct TripHistoryTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1; print("PASS: \(message)")
        }
        func recording(_ distance: Double, available: Bool? = nil) -> Trip {
            let details = available.map {
                RecordingDetails(endedAt: Date(), elapsedSeconds: 10, distanceAvailable: $0, distanceIsPartial: false, motionAvailable: false, calibrationDescription: "Test", events: [], motionSamples: [], gpsPoints: [], interruptions: [])
            }
            return Trip(id: UUID(), title: "Local test recording", date: Date(), distanceMiles: distance, durationMinutes: 0, harshBraking: 0, rapidAcceleration: 0, mpg: 0, fuelPrice: 0, modeledExcessGallons: 0, source: .measured, recording: details)
        }
        let legacy = recording(0)
        check(legacy.isIncompleteRecording && legacy.distanceLabel == "Unavailable", "legacy zero-distance recordings are incomplete, without invented mileage")
        check(recording(0, available: true).isIncompleteRecording, "a GPS flag alone does not make zero distance usable")
        check(recording(1, available: false).isIncompleteRecording, "unavailable GPS overrides a stored placeholder distance")
        check(recording(-1).isIncompleteRecording, "invalid negative distances remain incomplete")
        check(recording(.nan).isIncompleteRecording, "nonfinite distances remain incomplete")
        let valid = recording(1.25, available: true)
        check(!valid.isIncompleteRecording && valid.distanceLabel == "1.25 mi", "usable distance stays visible without inventing a price")
        check(recording(0.001, available: true).distanceLabel == "<0.01 mi", "a small known distance is not rounded into a false zero")
        check(!valid.hasEstimate && !legacy.hasEstimate, "presentation does not price local recordings")
        let demo = DemoData.snapshot.trips[0]
        check(demo.hasEstimate && !demo.isIncompleteRecording, "existing sample financial estimates are unchanged")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripStore(fileURL: directory.appendingPathComponent("trips.json"))
        try store.save([legacy, valid])
        // This snapshot client remains offline. AppViewModel has no authenticated backend client.
        let model = AppViewModel(store: store)
        await model.load()
        let crews = model.crews.map(\.id)
        check(model.isLocalTrip(legacy) && model.isLocalTrip(valid), "only persisted local recordings are deletable")
        check(!model.isLocalTrip(demo), "snapshot/sample rows are not offered for local deletion")
        try model.deleteLocalTrip(demo)
        check(model.trips.contains(where: { $0.id == demo.id }), "deleting a snapshot-only row is a no-op")
        try model.deleteLocalTrip(legacy)
        check(!model.trips.contains(where: { $0.id == legacy.id }), "deleted local recording leaves visible history")
        check(try store.load() == [valid], "deletion persists and retains the other recording exactly")
        check(model.crews.map(\.id) == crews, "local deletion leaves standings untouched")
        try model.deleteLocalTrip(legacy)
        check(try store.load() == [valid], "repeated deletion is harmless")
        let restored = AppViewModel(store: store)
        await restored.load()
        check(!restored.trips.contains(where: { $0.id == legacy.id }) && restored.isLocalTrip(valid), "deleted recordings stay absent after reload")
        try Data("corrupt".utf8).write(to: store.fileURL)
        do { try restored.deleteLocalTrip(valid); preconditionFailure("Expected persistence failure") }
        catch { check(restored.trips.contains(where: { $0.id == valid.id }) && restored.isLocalTrip(valid), "failed persistence retains the visible recording for retry") }
        try store.save([valid])
        try restored.deleteLocalTrip(valid)
        check(try store.load().isEmpty, "deleting the last local recording preserves a readable empty history")
        // A connected snapshot client must receive no upload/delete requests from local cleanup.
        try store.save([valid])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryNetworkSpy.self]
        let remote = APIClient.RemoteConfiguration(snapshotURL: URL(string: "https://example.invalid/snapshot")!, tripUploadURL: URL(string: "https://example.invalid/upload")!, snapshotMethod: "GET", tripUploadMethod: "POST", encodeTrip: { try JSONEncoder().encode($0) }, decodeSnapshot: { try JSONDecoder().decode(AppSnapshot.self, from: $0) })
        HistoryNetworkSpy.response = try JSONEncoder().encode(DemoData.snapshot)
        let connected = AppViewModel(client: APIClient(mode: .remote(remote), session: URLSession(configuration: configuration)), store: store)
        await connected.load()
        let requestsBeforeDeletion = HistoryNetworkSpy.methods
        try connected.deleteLocalTrip(valid)
        check(requestsBeforeDeletion == ["GET"] && HistoryNetworkSpy.methods == requestsBeforeDeletion, "local deletion sends no network request, including DELETE or upload")
        check(connected.trips.contains { $0.id == demo.id }, "remote snapshot data is retained after local deletion")
        print("\(count) local history checks passed.")
    }
}
