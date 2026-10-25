import Foundation
import SwiftUI

private final class CalculationCredentials: CredentialStore {
    var value: StoredCredential?
    func load() throws -> StoredCredential? { value }
    func save(_ credential: StoredCredential) throws { value = credential }
    func clear() throws { value = nil }
}
private final class CalculationStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
                captured.httpBody = data
            }
            let (status, data) = try Self.handler(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
private actor FixtureLoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
@main struct TestCalculationTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw BackendError.invalidInput("FAILED: " + label) }
        checks += 1; print("PASS: " + label)
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/\(name).json")) }
    @MainActor static func main() async throws {
        let fixture = try data("calculation-trip")
        let raw = try APIJSON.decoder().decode([String: JSONValue].self, from: fixture)
        let first = try SyntheticCalculationAttempt(fixture: fixture, clientTripID: UUID())
        let second = try SyntheticCalculationAttempt(fixture: fixture, clientTripID: UUID())
        let body = try APIJSON.decoder().decode([String: JSONValue].self, from: first.body)
        try check(first.clientTripID != second.clientTripID && body["source"] == .string("synthetic") && body["is_demo"] == .bool(true), "new tests have fresh UUIDs and mandatory synthetic/demo provenance")
        let changed = Set(raw.keys.filter { raw[$0] != body[$0] })
        try check(changed == ["client_trip_id", "source", "is_demo", "events"], "only trip/event identities and provenance change")
        let decoded = try APIJSON.decoder().decode(APITripPayload.self, from: first.body)
        try check(decoded.events_complete == true && decoded.detector_version == "ios-0.1.0" && decoded.speed_samples.count == 301, "actual fixture detector completeness and all 301 GPS samples survive upload")
        func measurements(_ value: JSONValue?) -> [JSONValue] {
            guard case .array(let values) = value else { return [] }
            return values.map { item in
                guard case .object(var event) = item else { return item }
                event["event_id"] = nil
                return .object(event)
            }
        }
        try check(measurements(body["events"]) == measurements(raw["events"]) && body["speed_samples"] == raw["speed_samples"], "durations, detector versions, turns, timestamps, speeds and GPS accuracy are not fabricated")
        let secondPayload = try APIJSON.decoder().decode(APITripPayload.self, from: second.body)
        try check(Set(decoded.events.map(\.event_id)).isDisjoint(with: secondPayload.events.map(\.event_id)), "event UUIDs are fresh across tests to avoid the backend global event key")
        var invalid = raw; invalid["events_complete"] = nil
        do { _ = try SyntheticCalculationAttempt(fixture: APIJSON.encoder().encode(invalid), clientTripID: UUID()); throw BackendError.invalidInput("Missing metadata accepted") }
        catch BackendError.invalidInput(let text) { try check(text.contains("missing"), "missing detector fields rejected instead of invented") }
        invalid = raw; invalid["latitude"] = .number(40)
        do { _ = try SyntheticCalculationAttempt(fixture: APIJSON.encoder().encode(invalid), clientTripID: UUID()); throw BackendError.invalidInput("Coordinates accepted") }
        catch BackendError.invalidInput(let text) { try check(text.contains("coordinates"), "coordinate-bearing fixture rejected before upload") }
        let receiptTemplate = try APIJSON.decoder().decode(APIReceipt.self, from: data("calculation-receipt"))
        try check(receiptTemplate.vehicle?.contains("Mazda5") == true && receiptTemplate.label != nil && receiptTemplate.high_speed_cost_usd == 0.1026 && receiptTemplate.notes?.count == 3, "current receipt pricing vehicle, label, high-speed cost and notes decode")
        let oldReceipt = try APIJSON.decoder().decode(APIReceipt.self, from: data("sample-receipt"))
        try check(oldReceipt.vehicle == nil && oldReceipt.notes == nil, "older receipts still decode without invented pricing metadata")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CalculationStub.self]
        let session = URLSession(configuration: config)
        CalculationStub.handler = { request in
            try check(request.url?.host == "raw.githubusercontent.com" && request.value(forHTTPHeaderField: "Authorization") == nil, "fixture download never receives API credentials")
            try check(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache", "each new test requests a fresh backend fixture")
            return (200, fixture)
        }
        try check(try await TestCalculationService.downloadLatestFixture(session: session) == fixture, "latest fixture loader returns authoritative bytes")
        CalculationStub.handler = { _ in (503, Data()) }
        do { _ = try await TestCalculationService.downloadLatestFixture(session: session); throw BackendError.invalidInput("Silent offline fallback") }
        catch BackendError.invalidInput(let text) { try check(text.contains("no offline"), "fixture failure never silently submits a bundled replacement") }
        let driverID = UUID(), testID = UUID(), serverID = UUID()
        let credentials = CalculationCredentials()
        let client = BackendAPIClient(mode: .remote(URL(string: "https://calculation.invalid")!), demoOnly: true, session: session, credentialStore: credentials)
        var postedBodies: [Data] = [], paths: [String] = [], putCount = 0, receiptCalls = 0
        let loads = FixtureLoadCounter()
        var losePostResponse = true, failReceipt = false, unscored = false
        let vehicle = try APIJSON.decoder().decode(VehicleRow.self, from: data("catalog-mazda5"))
        CalculationStub.handler = { request in
            let path = request.url!.path; paths.append(path)
            if path == "/users" {
                return (201, try APIJSON.encoder().encode(APIUser(user_id: testID, nickname: "Drive Save Calculation Demo", token: "isolated-test-only")))
            }
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer isolated-test-only", "protected calculation requests use only the isolated test credential")
            if path == "/users/me/vehicle" {
                try check(try APIJSON.decoder().decode(VehicleRow.self, from: request.httpBody!) == vehicle, "isolated account receives the exact saved vehicle")
                putCount += 1; return (200, try APIJSON.encoder().encode(vehicle))
            }
            if path == "/trips" {
                try check(putCount > 0 && paths[paths.count - 2] == "/users/me/vehicle", "vehicle PUT precedes each trip submission")
                postedBodies.append(request.httpBody!)
                if losePostResponse { losePostResponse = false; throw URLError(.networkConnectionLost) }
                return (postedBodies.count == 2 ? 200 : 201, try APIJSON.encoder().encode(APITripCreated(trip_id: serverID, receipt_url: "/trips/\(serverID)/receipt", duplicate: postedBodies.count == 2)))
            }
            guard path == "/trips/\(serverID)/receipt" else { throw BackendError.invalidInput("Unexpected endpoint") }
            receiptCalls += 1
            if failReceipt { failReceipt = false; throw URLError(.notConnectedToInternet) }
            if unscored { return (409, Data(#"{"error":{"code":"trip_not_scored","message":"speed_coverage_incomplete"}}"#.utf8)) }
            var receipt = receiptTemplate; receipt.trip_id = serverID
            return (200, try APIJSON.encoder().encode(receipt))
        }
        let service = TestCalculationService(api: client, driverID: driverID, fixtureLoader: { await loads.increment(); return fixture })
        let model = TestCalculationViewModel(vehicle: vehicle, service: service)
        await model.newTest()
        let retryID = model.clientTripID
        try check(model.errorMessage != nil && model.receipt == nil, "ambiguous POST failure shows an error without a local estimate")
        await model.retry()
        let firstLoadCount = await loads.count
        try check(model.clientTripID == retryID && postedBodies.count == 2 && postedBodies[0] == postedBodies[1] && firstLoadCount == 1, "retry preserves UUID, fixture, vehicle and identical body for duplicate handling")
        try check(model.receipt?.vehicle == receiptTemplate.vehicle && model.receipt?.avoidable_cost_usd == receiptTemplate.avoidable_cost_usd, "receipt displays actual server pricing vehicle and returned dollars")
        try check(credentials.value?.userID == testID && testID != driverID && !paths.contains(where: { $0.contains("crew") || $0.contains("leaderboard") }), "driver identity and real league endpoints are untouched")
        do { _ = try await client.createLeague(name: "Forbidden"); throw BackendError.invalidInput("League allowed") }
        catch BackendError.invalidInput(let text) { try check(text.contains("cannot"), "calculation account cannot enter league competition") }
        failReceipt = true
        await model.newTest()
        let postCount = postedBodies.count, newID = model.clientTripID
        let secondLoadCount = await loads.count
        try check(newID != retryID && secondLoadCount == 2 && model.errorMessage != nil && model.receipt == nil, "new test fetches a new fixture and clears old results even when receipt fetch fails")
        await model.retry()
        try check(postedBodies.count == postCount && model.clientTripID == newID && model.receipt != nil, "receipt-only retry does not re-upload or generate another trip")
        unscored = true; await model.newTest()
        try check(model.notScored && model.receipt == nil && model.errorMessage?.contains("speed_coverage_incomplete") == true, "trip_not_scored shows backend reason with no fabricated price")
        let errorData = Data(#"{"error":{"code":"trip_not_scored","message":"not enough samples"}}"#.utf8)
        let envelope = try APIJSON.decoder().decode(APIErrorEnvelope.self, from: errorData)
        let text = BackendError.server(409, envelope.error).localizedDescription
        try check(text.contains("not scored") && !text.contains("Trip conflict"), "unscored receipt is not mislabeled as a UUID conflict")
        unscored = false; await model.newTest()
        try check(!model.notScored && model.errorMessage == nil && model.receipt != nil, "a new test can succeed after an unscored result")
        let collisionStore = CalculationCredentials()
        collisionStore.value = StoredCredential(userID: driverID, nickname: "Real driver", token: "must-never-be-used", isDemoAccount: false)
        let collision = BackendAPIClient(mode: .remote(URL(string: "https://calculation.invalid")!), demoOnly: true, session: session, credentialStore: collisionStore)
        let oldPathCount = paths.count
        do { try await collision.ensureCalculationIdentity(driverID: driverID); throw BackendError.invalidInput("Driver identity allowed") }
        catch BackendError.invalidInput(let text) { try check(text.contains("different") && paths.count == oldPathCount, "credential collision with driver account is rejected before protected requests") }
        let ordinary = BackendAPIClient(mode: .remote(URL(string: "https://calculation.invalid")!), session: session, credentialStore: CalculationCredentials())
        do { try await ordinary.ensureCalculationIdentity(driverID: driverID); throw BackendError.invalidInput("Ordinary client allowed") }
        catch BackendError.invalidInput(let text) { try check(text.contains("isolated") && paths.count == oldPathCount, "ordinary API client cannot be used for calculation tests") }
        print("\(checks) test-calculation checks passed.")
    }
}
