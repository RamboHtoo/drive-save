import Foundation

final class PresentationCredentialStore: CredentialStore {
    var credential: StoredCredential?
    var writes = 0
    func load() throws -> StoredCredential? { credential }
    func save(_ value: StoredCredential) throws { credential = value; writes += 1 }
    func clear() throws { credential = nil; writes += 1 }
}
final class PresentationStub: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)!
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        do {
            let data = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct PresentationTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw BackendError.invalidInput("FAIL: " + message) }
        checks += 1
    }
    @MainActor static func main() async throws {
        try check(PresentationData.players.map(\.name) == ["Htoo", "Alex", "Jordan", "Sam", "Taylor", "Casey"], "all six players in cost order")
        try check(PresentationData.players.map(\.costCents) == [142,185,240,312,430,575], "exact requested costs")
        try check(PresentationData.players.map { PresentationData.rank(of: $0) } == [1,2,3,4,5,6], "lowest first, highest last")
        try check(PresentationData.trips.count == 8 && Set(PresentationData.trips.map(\.id)).count == 8, "eight distinct fictional display trips")
        try check(PresentationData.trips.reduce(0) { $0 + $1.costCents } == 142, "integer-cent sum is exactly $1.42")
        try check(PresentationData.trips.reduce(0) { $0 + $1.distanceTenths } == 634, "exact 63.4 sample miles")
        try check(PresentationData.weeklyCost == "$1.42" && PresentationData.weeklyDistance == "63.4", "consistent display totals")
        try check(PresentationData.players.first!.cost == PresentationData.weeklyCost, "leaderboard and dashboard share one total")
        try check(PresentationData.presenterRank == "#1 of 6" && PresentationData.players.filter(\.isPresenter).count == 1, "only Htoo is highlighted")
        try check(PresentationData.vehicle == "2015 Audi A4" && PresentationData.improvement == "18% less waste", "sample profile and informational improvement")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let owner = UUID(), crew = UUID(), credentials = PresentationCredentialStore()
        try credentials.save(.init(userID: owner, nickname: "Htoo", token: "isolated-local-token", isDemoAccount: false))
        let league = APILeague(crew_id: crew, name: "Actual Test League", join_code: "KEEP42", members: [.init(user_id: owner, nickname: "Htoo", joined_at: Date(timeIntervalSince1970: 1_700_000_000))], member_count: 1, active: false, is_demo: false)
        let progress = APIProgress(user_id: owner, trips_counted: 0, baseline_trips_needed: 3, baseline_waste_per_mile_usd: nil, current_waste_per_mile_usd: nil, improvement_pct: nil, est_savings_usd: 0, weekly: [], is_estimate: true)
        PresentationStub.handler = { request in
            if request.url!.path.hasSuffix("/progress") { return try APIJSON.encoder().encode(progress) }
            if request.url!.path == "/crews" || request.url!.path == "/crews/\(crew)" { return try APIJSON.encoder().encode(league) }
            throw URLError(.unsupportedURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresentationStub.self]
        let client = BackendAPIClient(mode: .remote(URL(string: "https://presentation.invalid")!), session: URLSession(configuration: configuration), credentialStore: credentials)
        let backendFile = folder.appendingPathComponent("backend.json")
        let backend = BackendViewModel(storageURL: backendFile)
        await backend.connect(remote: true, baseURL: "https://presentation.invalid", client: client)
        await backend.createLeague(name: "Actual Test League") // Intercepted fixture setup only.
        await backend.refreshProgress()
        let vehicleJSON = try String(contentsOfFile: "DriveAndSave/MockData/Backend/catalog-mazda5.json", encoding: .utf8)
        backend.selectVehicle(json: vehicleJSON, confirmed: true)
        // Vehicle selection intentionally invalidates progress, so reload the actual fixture.
        await backend.refreshProgress()
        let tripFile = folder.appendingPathComponent("trips.json")
        let tripStore = TripStore(fileURL: tripFile)
        let model = AppViewModel(store: tripStore)
        let savedTrip = DemoData.snapshot.trips[0]
        try model.save(savedTrip)
        let identityBefore = backend.identity, vehicleBefore = backend.vehicle, progressBefore = backend.progress
        let leagueBefore = try APIJSON.encoder().encode(backend.league)
        let backendBefore = try Data(contentsOf: backendFile), tripsBefore = try Data(contentsOf: tripFile)
        let credentialBefore = try APIJSON.encoder().encode(credentials.credential)
        let writesBefore = credentials.writes, requestsBefore = PresentationStub.requests
        let actualCost = model.avoidableCost
        PresentationStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        let presentation = PresentationState()
        try check(!presentation.isEnabled, "actual data is the safe default")
        for _ in 0..<20 {
            presentation.isEnabled = true
            _ = PresentationData.players; _ = PresentationData.trips; _ = PresentationData.weeklyCost
            presentation.isEnabled = false
        }
        try check(PresentationStub.requests == requestsBefore, "switching and reading sample screens makes zero API requests, including uploads")
        try check(credentials.writes == writesBefore && (try APIJSON.encoder().encode(credentials.credential)) == credentialBefore, "credential record and token unchanged")
        try check(backend.identity == identityBefore, "existing account identity unchanged")
        try check(backend.vehicle == vehicleBefore && backend.vehicleConfirmed, "actual vehicle and confirmation unchanged")
        try check(backend.progress == progressBefore && backend.progress?.trips_counted == 0, "real zero-trip progress never replaced by sample eight trips")
        try check((try APIJSON.encoder().encode(backend.league)) == leagueBefore, "real membership and invite code unchanged")
        try check((try Data(contentsOf: backendFile)) == backendBefore, "persistent account, vehicle, uploads and receipt cache byte-for-byte unchanged")
        try check((try Data(contentsOf: tripFile)) == tripsBefore && model.trips.count == 1 && model.avoidableCost == actualCost, "history file, visible actual records and actual total unchanged")
        try check(!PresentationState().isEnabled, "new session starts in actual mode")
        print("\(checks) presentation isolation checks passed. No real credentials, server, or account accessed.")
    }
}
