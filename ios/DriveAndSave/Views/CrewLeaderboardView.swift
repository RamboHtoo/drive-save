import SwiftUI

struct CrewLeaderboardView: View {
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Screen {
            if !backend.isRemote { Eyebrow(text: "Offline demo · no multiplayer") }
            DisplayType(backend.league?.name ?? "Leagues", size: 48).accessibilityAddTraits(.isHeader).accessibilityIdentifier("leagueHeadline")
            if backend.league == nil { leagueActionLayout }
            if let league = backend.league {
                Surface {
                    if league.is_demo { Eyebrow(text: backend.isRemote ? "Demo league · experimental scoring" : "Offline demo league") }
                    Text("\(league.member_count) \(league.member_count == 1 ? "member" : "members") · \(league.canRank ? "Ranked" : "4 needed to rank")").font(.headline)

                    LeagueInviteActions(league: league)
                }
                if league.canRank {
                    Eyebrow(text: "Standings")
                    if backend.leaderboardIsDemo && !league.is_demo { Eyebrow(text: "Demo league · experimental scoring") }
                    if backend.standings.isEmpty {
                        Text("Rankings begin after 3 eligible trips per driver.").foregroundStyle(DS.secondary)
                        ForEach(league.members) { member in
                            ChampionshipRow(rank: nil, name: member.nickname, result: "Awaiting baseline", detail: "", isCurrent: member.user_id == backend.identity?.userID)
                        }
                    }
                    ForEach(backend.standings) { standing in
                        ChampionshipRow(rank: standing.rank, name: standing.nickname,
                            result: standing.improvement_pct.map { String(format: "%.1f%% improvement", $0) } ?? standing.availability,
                            detail: standing.rank == nil ? "" : "\(standing.trips_counted) trips · \(standing.est_savings_usd.receiptDollars) estimated",
                            isCurrent: standing.user_id == backend.identity?.userID)
                    }
                } else {
                    Eyebrow(text: "Drivers")
                    ForEach(league.members) { member in
                        ChampionshipRow(rank: nil, name: member.nickname, result: "Not ranked", detail: "", isCurrent: member.user_id == backend.identity?.userID)
                    }
                }
            } else {
                Surface {
                    Text("No league joined").font(DS.section)
                    Text("Create or join a league. 4 members needed to rank.").foregroundStyle(DS.secondary)
                }
            }
            if backend.league != nil {
                DisclosureGroup("Manage league") { leagueActionLayout.padding(.top, 12) }
            }
            ConsumerBackendStatusView()
        }.navigationTitle("Leagues").navigationBarTitleDisplayMode(.inline)
            .refreshable { await backend.refreshLeague() }
            .task { if backend.identity != nil { await backend.refreshLeague() } }
    }
    private var leagueActionLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { leagueActions }
            VStack(spacing: 12) { leagueActions }
        }
    }
    private var leagueActions: some View {
        Group {
            NavigationLink("Create League") { LeagueFormView(creating: true) }
                .buttonStyle(IgnitionButtonStyle())
            NavigationLink("Join League") { LeagueFormView(creating: false) }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 64)
                .foregroundStyle(DS.ink).overlay(Rectangle().stroke(DS.rule, lineWidth: 1))
        }
    }
}

struct ChampionshipRow: View {
    let rank: Int?
    let name: String
    let result: String
    let detail: String
    let isCurrent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) { rankNumber; driver; Spacer(minLength: 8); Text(result).font(.subheadline.monospaced()).foregroundStyle(DS.ink) }
                VStack(alignment: .leading, spacing: 10) { HStack(alignment: .firstTextBaseline, spacing: 16) { rankNumber; driver }; Text(result).font(.subheadline.monospaced()) }
            }
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(.vertical, 16).padding(.leading, isCurrent ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { if isCurrent { Rectangle().fill(DS.acid).frame(width: 3).padding(.vertical, 16) } }
            .overlay(alignment: .bottom) { MeasurementRule() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isCurrent ? "currentDriverStanding" : "standing-\(name)")
    }
    private var rankNumber: some View { DisplayType(rank.map { String(format: "%02d", $0) } ?? "—", size: 42) }
    private var driver: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline).foregroundStyle(DS.ink)
            if isCurrent { Text("YOU").font(DS.technical).foregroundStyle(DS.acid) }
        }
    }
}

struct QualificationMarks: View {
    let memberCount: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<4) { index in Rectangle().fill(index < memberCount ? DS.acid : DS.rule).frame(height: 4) }
        }.accessibilityLabel("\(min(memberCount, 4)) of 4 membership requirements met")
    }
}

struct LeagueFormView: View {
    let creating: Bool
    @EnvironmentObject private var backend: BackendViewModel
    @State private var name = ""
    @State private var leagueID = ""
    @State private var inviteCode = ""
    @State private var invitation = ""
    var body: some View {
        Screen {
            Surface {
                if creating {
                    TextField("League name", text: $name).accessibilityIdentifier("leagueName")
                    Text("4 members needed to rank.").font(.caption).foregroundStyle(DS.secondary)
                    Button("Create League") { Task { await backend.createLeague(name: name) } }.accessibilityIdentifier("createLeague")
                } else {
                    TextField("Paste full invitation", text: $invitation, axis: .vertical).accessibilityIdentifier("leagueInvitation")
                        .onChange(of: invitation) { _, value in
                            if let invite = LeagueInvitation.parse(value) { leagueID = invite.id.uuidString; inviteCode = invite.code }
                        }
                    DisclosureGroup("Enter invite details manually") {
                    TextField("League ID", text: $leagueID).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("leagueUUID")
                    TextField("Invite code", text: $inviteCode).textInputAutocapitalization(.characters).autocorrectionDisabled().accessibilityIdentifier("leagueCode")
                    }
                    Text("Joining leaves your previous league.").font(.caption).foregroundStyle(DS.secondary)
                    Button("Join League") { Task { await backend.joinLeague(id: leagueID, code: inviteCode) } }.accessibilityIdentifier("joinLeague")
                }
            }.buttonStyle(IgnitionButtonStyle()).disabled(backend.isBusy)
            if let league = backend.league { Text("Current league: \(league.name)").font(.headline).foregroundStyle(DS.mint) }
            ConsumerBackendStatusView()
        }.navigationTitle(creating ? "Create League" : "Join League").navigationBarTitleDisplayMode(.inline)
    }
}
