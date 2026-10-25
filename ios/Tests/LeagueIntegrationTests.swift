import Foundation

final class MemoryCredentialStore: CredentialStore {
    var credential: StoredCredential?
    func clear() throws { credential = nil }
    func load() throws -> StoredCredential? { credential }
    func save(_ credential: StoredCredential) throws { self.credential = credential }
}
final class BackendStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = data
            }
            let (status, data) = try Self.handler(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct LeagueIntegrationTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw BackendError.invalidInput("FAIL: " + message) }
        checks += 1
    }
    @MainActor static func main() async throws {
        let store = MemoryCredentialStore(), owner = UUID(), crew = UUID()
        try store.save(.init(userID: owner, nickname: "Driver", token: "offline-test-token", isDemoAccount: false))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BackendStub.self]
        let client = BackendAPIClient(mode: .remote(URL(string: "https://integration.invalid")!), session: URLSession(configuration: config), credentialStore: store)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("league-regression-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let league = APILeague(crew_id: crew, name: "Friends", join_code: "OFFLINE", members: [], member_count: 1, active: false, is_demo: false)
        var status = 200, code = "", reads = 0, rankingForbidden = false
        BackendStub.handler = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-test-token" else { throw BackendError.invalidInput("Unexpected credentials") }
            if request.url!.path == "/leaderboard/costs" { return (404, Data()) }
            if request.url!.path.hasSuffix("/leaderboard") {
                return (403, Data("{\"error\":{\"code\":\"forbidden\",\"message\":\"rank denied\"}}".utf8))
            }
            if request.httpMethod == "GET" { reads += 1 }
            if status != 200 {
                return (status, Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"controlled refusal\"}}".utf8))
            }
            var response = league
            if rankingForbidden { response.active = true; response.member_count = 4 }
            return (200, try APIJSON.encoder().encode(response))
        }
        let vm = BackendViewModel(storageURL: file)
        await vm.connect(remote: true, baseURL: "https://integration.invalid", client: client)
        await vm.createLeague(name: "Friends")
        try check(vm.league?.crew_id == crew && reads == 1, "valid league create and refresh preserve saved crew")
        for failure in [(500, "forbidden"), (404, "not_found"), (403, "other_reason")] {
            status = failure.0; code = failure.1
            await vm.refreshLeague()
            try check(vm.league?.crew_id == crew && vm.errorMessage != nil, "unrelated HTTP \(status) \(code) retains cached league")
        }
        status = 200; rankingForbidden = true
        await vm.refreshLeague()
        try check(vm.league?.crew_id == crew && vm.errorMessage != nil, "leaderboard forbidden does not invalidate membership")
        rankingForbidden = false; status = 409; code = "mixed_trip_sources"
        await vm.joinLeague(id: crew.uuidString, code: "OFFLINE")
        try check(vm.consumerErrorMessage?.contains("separate accounts") == true, "source conflict has clear consumer explanation")
        try check(vm.league?.crew_id == crew && store.credential?.userID == owner, "source conflict preserves league and identity")
        status = 403; code = "forbidden"
        await vm.refreshLeague()
        try check(vm.league == nil && vm.standings.isEmpty && vm.errorMessage == nil, "exact membership forbidden returns no-league state")
        try check(vm.identity?.userID == owner && store.credential?.token == "offline-test-token", "stale league removal never clears credentials")
        let before = reads
        let restored = BackendViewModel(storageURL: file)
        await restored.connect(remote: true, baseURL: "https://integration.invalid", client: client)
        await restored.refreshLeague()
        try check(reads == before && restored.league == nil, "stale league ID removal survives relaunch without repeat request")
        try check(restored.identity?.userID == owner, "relaunch keeps original account")
        // Actual view-model retry path, entirely intercepted; never a physical-drive claim.
        let fixture = try APIJSON.decoder().decode(APITripPayload.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/calculation-trip.json")))
        let rowData = try Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/catalog-mazda5.json"))
        let row = try APIJSON.decoder().decode(VehicleRow.self, from: rowData)
        restored.selectVehicle(json: String(decoding: rowData, as: UTF8.self), confirmed: true)
        let frozen = restored.recordingContext()!
        let detail = RecordingDetails(endedAt: fixture.ended_at, elapsedSeconds: 300, distanceAvailable: true, distanceIsPartial: false, motionAvailable: true, calibrationDescription: "Controlled offline fixture", events: [], motionSamples: [], gpsPoints: [], interruptions: [], speedSamples: fixture.speed_samples, eventsComplete: true, detectorVersion: CandidateEventDetector.version)
        let local = Trip(id: UUID(), title: "Controlled retry fixture", date: fixture.started_at, distanceMiles: fixture.distance_mi, durationMinutes: 5, harshBraking: 0, rapidAcceleration: 0, mpg: 0, fuelPrice: 0, modeledExcessGallons: 0, source: .measured, recording: detail, clientTripID: UUID(), recordingContext: frozen)
        let otherRow = try Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/catalog-cybertruck.json"))
        restored.selectVehicle(json: String(decoding: otherRow, as: UTF8.self), confirmed: true)
        var posts = 0, receiptReads = 0
        var failVehicle = false, failPost = false, failReceipt = false, scoreReceipt = false
        let serverTrip = UUID()
        var permittedIDs: Set<UUID> = [local.clientTripID!]
        BackendStub.handler = { request in
            if request.url!.path == "/users/me/vehicle" {
                if failVehicle { return (500, Data()) }
                let submitted = try APIJSON.decoder().decode(VehicleRow.self, from: request.httpBody!)
                guard submitted == row else { throw BackendError.invalidInput("Starting vehicle substituted") }
                return (200, rowData)
            }
            if request.url!.path == "/trips" {
                posts += 1
                if failPost { throw URLError(.networkConnectionLost) }
                let submitted = try APIJSON.decoder().decode(APITripPayload.self, from: request.httpBody!)
                guard permittedIDs.contains(submitted.client_trip_id) else { throw BackendError.invalidInput("UUID changed") }
                return (201, try APIJSON.encoder().encode(APITripCreated(trip_id: serverTrip, receipt_url: "/trips/\(serverTrip)/receipt", duplicate: false)))
            }
            if request.url!.path.hasSuffix("/receipt") {
                receiptReads += 1
                if failReceipt { throw URLError(.networkConnectionLost) }
                if scoreReceipt {
                    var receipt = try APIJSON.decoder().decode(APIReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/calculation-receipt.json")))
                    receipt.trip_id = serverTrip
                    return (200, try APIJSON.encoder().encode(receipt))
                }
                return (422, Data("{\"error\":{\"code\":\"trip_not_scored\",\"message\":\"controlled missing evidence\"}}".utf8))
            }
            return (500, Data()) // Progress is intentionally unavailable; never substituted with money.
        }
        try check(restored.uploadDiagnostics(for: local).state == .ready && posts == 0, "saving/selecting a local trip does not initiate POST")
        var invalid = local; invalid.clientTripID = UUID(); invalid.recording?.eventsComplete = false
        await restored.upload(trip: invalid)
        let blocked = restored.uploadDiagnostics(for: invalid)
        try check(posts == 0 && blocked.state == .notEligible && blocked.trace?.postAttemptedAt == nil, "known-invalid recording never reaches POST")
        try check(blocked.trace?.stage == .preflight && blocked.preflightFailure == restored.unsupportedReason(for: invalid), "real gate and displayed preflight use identical failure order")
        await restored.upload(trip: local)
        let refused = restored.uploadDiagnostics(for: local)
        try check(refused.state == .notScored && refused.serverTripID == serverTrip && refused.trace?.postAttemptCount == 1, "POST acceptance plus scoring refusal is explicitly tracked")
        try check(refused.trace?.lastError?.contains("trip_not_scored") == true, "server refusal preserves HTTP error code for diagnostics")
        await restored.upload(trip: local)
        try check(posts == 1 && receiptReads == 2, "receipt retry reuses saved server trip without duplicate POST")
        try check(restored.insufficientReason(for: local)?.contains("controlled missing evidence") == true && restored.receipt(for: local) == nil, "refused receipt retains reason and no financial result")
        let wrongContext = RecordingContext(ownerID: UUID(), accountScope: frozen.accountScope, vehicle: row, vehicleConfirmed: true)
        var wrong = local; wrong.recordingContext = wrongContext
        await restored.upload(trip: wrong)
        try check(posts == 1 && restored.errorMessage?.contains("different account") == true, "wrong-owner recording refused before POST")
        let reread = BackendViewModel(storageURL: file)
        await reread.connect(remote: true, baseURL: "https://integration.invalid", client: client)
        await reread.upload(trip: local)
        try check(posts == 1 && receiptReads == 3, "persisted retry keeps original UUID and vehicle after relaunch")
        try check(reread.uploadDiagnostics(for: local).state == .notScored && reread.uploadDiagnostics(for: local).trace?.postAttemptCount == 1, "acceptance, refusal and actual POST count survive relaunch")
        var putFailure = local; putFailure.clientTripID = UUID(); permittedIDs.insert(putFailure.clientTripID!)
        failVehicle = true
        await reread.upload(trip: putFailure)
        let beforePost = reread.uploadDiagnostics(for: putFailure)
        try check(beforePost.trace?.stage == .vehicle && beforePost.trace?.postAttemptedAt == nil && posts == 1, "vehicle HTTP failure is not mislabeled as attempted POST")
        failVehicle = false; failPost = true
        await reread.upload(trip: putFailure)
        let attempted = reread.uploadDiagnostics(for: putFailure)
        try check(attempted.state == .attempted && attempted.serverTripID == nil && attempted.trace?.postAttemptCount == 1, "network failure at POST cannot claim server acceptance")
        failPost = false; failReceipt = true
        await reread.upload(trip: putFailure)
        let accepted = reread.uploadDiagnostics(for: putFailure)
        try check(accepted.state == .accepted && accepted.serverTripID == serverTrip && accepted.trace?.stage == .receipt, "accepted POST with interrupted receipt is pending, not unscored")
        failReceipt = false; scoreReceipt = true
        let postsBeforeReceipt = posts
        await reread.upload(trip: putFailure)
        try check(reread.uploadDiagnostics(for: putFailure).state == .scored && posts == postsBeforeReceipt, "successful receipt retrieval transitions to scored without another POST")
        let foreignStore = MemoryCredentialStore()
        try foreignStore.save(.init(userID: UUID(), nickname: "Other", token: "other-offline-token", isDemoAccount: false))
        let foreignClient = BackendAPIClient(mode: .remote(URL(string: "https://integration.invalid")!), session: URLSession(configuration: config), credentialStore: foreignStore)
        let foreign = BackendViewModel(storageURL: file)
        await foreign.connect(remote: true, baseURL: "https://integration.invalid", client: foreignClient)
        let scoped = foreign.uploadDiagnostics(for: putFailure)
        try check(scoped.trace == nil && scoped.serverTripID == nil && scoped.state == .notEligible, "different account cannot read cached transport or receipt status")
        // Decode the old cache schema without inventing historical attempt evidence.
        var oldState = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        oldState.removeValue(forKey: "uploadTraces")
        try JSONSerialization.data(withJSONObject: oldState).write(to: file)
        let oldVM = BackendViewModel(storageURL: file)
        await oldVM.connect(remote: true, baseURL: "https://integration.invalid", client: client)
        try check(oldVM.uploadDiagnostics(for: local).state == .notScored && oldVM.uploadDiagnostics(for: local).trace == nil, "old accepted uploads decode with known acceptance and unknown attempt dates")
        print("\(checks) league view-model integration checks passed")
    }
}
