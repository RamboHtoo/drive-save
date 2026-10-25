import Foundation

/// Opt-in production smoke: four new dedicated accounts and one new league, no trips/deletes.
private final class LeagueTestCredentials: CredentialStore {
    var credential: StoredCredential?
    func load() throws -> StoredCredential? { credential }
    func save(_ credential: StoredCredential) throws { self.credential = credential }
    func clear() throws { credential = nil }
}

@main struct LiveLeagueSmoke {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw BackendError.invalidInput("TEST FAILED: " + message) }
        print("PASS: " + message)
    }
    static func main() async throws {
        let base = URL(string: "https://drivesave.nuhylabs.com")!
        let tag = String(UUID().uuidString.prefix(8))
        let stores = (0..<4).map { _ in LeagueTestCredentials() }
        let clients = stores.map { BackendAPIClient(mode: .remote(base), credentialStore: $0) }
        var identities: [APIIdentity] = []
        for index in clients.indices {
            identities.append(try await clients[index].register(nickname: "iOS League Test \(tag) \(index + 1)", demoAccount: false))
        }
        try check(Set(identities.map(\.userID)).count == 4, "four separate clients register four unique drivers")
        let league = try await clients[0].createLeague(name: "iOS Four Test \(tag)")
        try check(league.member_count == 1 && !league.canRank, "new league reports one member and is unranked")
        guard let code = league.join_code else { throw BackendError.invalidResponse }
        for index in 1..<4 {
            let joined = try await clients[index].joinLeague(id: league.crew_id, code: code)
            try check(joined.member_count == index + 1, "joining driver \(index + 1) updates member count")
        }
        for index in clients.indices {
            let restored = BackendAPIClient(mode: .remote(base), credentialStore: stores[index])
            try check(try await restored.identity() == identities[index], "driver \(index + 1) restores the same identity without re-registering")
            let progress = try await restored.progress()
            try check(progress.user_id == identities[index].userID && progress.trips_counted == 0 && !progress.hasSavings, "driver \(index + 1) reads real empty progress under their own identity")
            let loaded = try await restored.league(id: league.crew_id)
            try check(loaded.member_count == 4 && loaded.canRank && Set(loaded.members.map(\.user_id)) == Set(identities.map(\.userID)), "driver \(index + 1) reads all four named members in the shared league")
            let board = try await restored.leaderboard(id: league.crew_id)
            try check(board.crew_id == league.crew_id && board.member_count == 4 && board.active, "driver \(index + 1) sees the correct active member leaderboard")
            try check(Set(board.standings.map(\.user_id)) == Set(identities.map(\.userID)) && board.standings.allSatisfy { $0.rank == nil && $0.improvement_pct == nil }, "driver \(index + 1) sees individual names awaiting eligible driving baselines, without invented ranks")
        }
        print("Four-account live league smoke passed. No trips, resets, or deletes sent. Dedicated test league remains on the server.")
    }
}
