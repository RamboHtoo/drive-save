import Foundation

/// Opt-in live check. Dedicated disposable accounts only. No token logging or disk persistence.
private final class EphemeralCredentials: CredentialStore {
    var value: StoredCredential?
    func clear() throws { value = nil }
    func load() throws -> StoredCredential? { value }
    func save(_ credential: StoredCredential) throws { value = credential }
}
@main struct LiveClientSmoke {
    static func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try APIJSON.decoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/\(name).json")))
    }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw BackendError.invalidInput(message) }
        print("PASS: " + message)
    }
    static func main() async throws {
        let url = URL(string: "https://drivesave.nuhylabs.com")!
        let replay = BackendAPIClient(mode: .remote(url), demoOnly: true, credentialStore: EphemeralCredentials())
        _ = try await replay.register(nickname: "iOS Swift Replay " + String(UUID().uuidString.prefix(6)), demoAccount: true)
        let vehicle = try fixture("sample-vehicle", as: VehicleRow.self)
        var trip = try fixture("sample-trip", as: APITripPayload.self)
        trip.client_trip_id = UUID(); trip.source = "replayed"; trip.is_demo = true
        let created = try await replay.upload(trip, vehicle: vehicle)
        let duplicate = try await replay.upload(trip, vehicle: vehicle)
        try require(!created.duplicate && duplicate.duplicate && created.trip_id == duplicate.trip_id, "Swift client registration, vehicle-first upload, 201 and duplicate 200")
        let returnedVehicle = try await replay.getVehicle()
        try require(returnedVehicle == vehicle, "Swift client preserves complete EPA JSON")
        let receipt = try await replay.receipt(tripID: created.trip_id)
        try require(receipt.is_demo && receipt.is_estimate && !receipt.cost_model.isEmpty && !receipt.assumptions.isEmpty, "Swift receipt decoder handles live fields and dated assumptions")
        do { _ = try await replay.createLeague(name: "Should never be created"); throw BackendError.invalidInput("Expected isolation rejection") }
        catch BackendError.invalidInput(let message) { try require(message.contains("Isolated replay"), "Replay identity cannot enter a league") }
        let owner = BackendAPIClient(mode: .remote(url), credentialStore: EphemeralCredentials())
        _ = try await owner.register(nickname: "iOS Swift League " + String(UUID().uuidString.prefix(6)), demoAccount: true)
        let league = try await owner.createLeague(name: "iOS Swift Disposable " + String(UUID().uuidString.prefix(6)))
        let joiner = BackendAPIClient(mode: .remote(url), credentialStore: EphemeralCredentials())
        _ = try await joiner.register(nickname: "iOS Swift Join " + String(UUID().uuidString.prefix(6)), demoAccount: true)
        guard let code = league.join_code else { throw BackendError.invalidResponse }
        let joined = try await joiner.joinLeague(id: league.crew_id, code: code)
        let loaded = try await owner.league(id: league.crew_id)
        let board = try await owner.leaderboard(id: league.crew_id)
        try require(joined.member_count == 2 && !loaded.canRank && board.crew_id == league.crew_id && !board.active, "Swift league create/join/get and current member leaderboard decode")
        try require(board.standings.allSatisfy { $0.rank == nil && $0.improvement_pct == nil }, "Drivers without real eligible trips remain unranked")
        print("Live Swift client smoke passed. Replay identity stayed isolated; test league remains inactive.")
    }
}
