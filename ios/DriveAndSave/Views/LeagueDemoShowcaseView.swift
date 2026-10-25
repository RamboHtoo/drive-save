import SwiftUI

/// Opt-in presentation of examples in the SAME league; no seed/write controls on the phone.
struct LeagueDemoShowcaseView: View {
    @EnvironmentObject private var backend: BackendViewModel
    @State private var board: APILeaderboard?
    @State private var error: String?
    @State private var setup: String?
    @State private var loading = false
    var body: some View {
        Screen {
            DisplayType(backend.league?.name ?? "League", size: 40)
            Surface {
                Eyebrow(text: "Demo showcase · example costs")
                Text("Fictional players use supplied examples. This showcase does not affect competition, financial progress or trip history.")
                    .font(.subheadline).foregroundStyle(DS.secondary)
                Text("Lowest weekly estimated avoidable fuel cost first. Unscored trips are excluded.").font(.caption).foregroundStyle(DS.secondary)
                if !backend.isRemote { Text("Offline fixture · no server data").font(.caption).foregroundStyle(DS.acid) }
            }
            if loading { ProgressView() }
            if let board {
                Text("\(board.member_count) members").font(.headline).accessibilityIdentifier("showcaseMemberCount")
                ForEach(board.standings) { standing in
                    ChampionshipRow(rank: standing.rank, name: standing.nickname,
                        result: standing.rank == nil ? "Not ranked" : standing.weekly_avoidable_cost_usd?.receiptDollars ?? "Unavailable",
                        detail: standing.is_synthetic_demo == true ? "SYNTHETIC DEMO · supplied example · excluded from genuine competition" : "Recorded scored trips only · no example costs added",
                        isCurrent: standing.user_id == backend.identity?.userID)
                }
            }
            if let error { Text(error).font(.subheadline).foregroundStyle(DS.secondary).accessibilityIdentifier("showcaseUnavailable") }
            Button("Refresh showcase") { Task { await load() } }.disabled(loading)
            if backend.isRemote {
                Button("Verify and export existing league") {
                    Task {
                        do { setup = try await backend.authenticatedLeagueSetup() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(loading)
                if let setup {
                    Text(setup).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink(item: setup, subject: Text("Authenticated Drive Save league setup")) { Text("Share verified setup") }
                }
            }
        }.navigationTitle("Demo showcase").navigationBarTitleDisplayMode(.inline).task { await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do { board = try await backend.fetchLeagueShowcase() }
        catch {
            board = nil
            self.error = "The demo showcase is unavailable on this server. No players or trips were created. The reviewed backend extension must be enabled first."
        }
    }
}
