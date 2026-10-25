import SwiftUI

struct CrewLeaderboardView: View {
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Screen {
            Eyebrow(text: backend.isRemote ? "ONLINE / PRIVATE CHAMPIONSHIP" : "OFFLINE DEMO / NO MULTIPLAYER")
            DisplayType("THE GRID.", size: 60).accessibilityAddTraits(.isHeader).accessibilityIdentifier("leagueHeadline")
            Text("Individual drivers. One league.\nLess waste earns the advantage.").font(.title3).foregroundStyle(DS.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { leagueActions }
                VStack(spacing: 12) { leagueActions }
            }
            if let league = backend.league {
                Surface {
                    Eyebrow(text: "Your private league")
                    Text(league.name).font(DS.section)
                    if league.is_demo { DemoNotice() }
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        DisplayType(String(format: "%02d", league.member_count), size: 56)
                        Text("MEMBERS").font(DS.technical).foregroundStyle(DS.secondary)
                    }
                    Text("\(league.member_count) members · \(league.canRank ? "Ranked league" : "Unranked — needs 4+ members")").font(.subheadline).foregroundStyle(DS.secondary)
                    QualificationMarks(memberCount: league.member_count)
                    Text(league.canRank ? "Individual baselines determine who can be ranked." : "Four members activate ranked play. Individual driving baselines are still required.").font(.caption).foregroundStyle(DS.secondary)
                    Text("League ID: \(league.crew_id.uuidString)").font(.caption.monospaced()).textSelection(.enabled)
                    LeagueInviteActions(league: league)
                    Button("Refresh league & drivers") { Task { await backend.refreshLeague() } }.disabled(backend.isBusy)
                }
                if league.canRank {
                    Eyebrow(text: "Individual driver rankings")
                    if backend.leaderboardIsDemo { DemoNotice() }
                    if backend.standings.isEmpty {
                        Text("No ranked driving data yet. Baselines need the first 3 eligible trips.").foregroundStyle(DS.secondary)
                        ForEach(league.members) { member in
                            ChampionshipRow(rank: nil, name: member.nickname, result: "Awaiting baseline", detail: "No driver rank returned yet", isCurrent: member.user_id == backend.identity?.userID)
                        }
                    }
                    ForEach(backend.standings) { standing in
                        ChampionshipRow(rank: standing.rank, name: standing.nickname,
                            result: standing.improvement_pct.map { String(format: "%.1f%% improvement", $0) } ?? "Awaiting baseline",
                            detail: "\(standing.trips_counted) trips counted · \(standing.est_savings_usd.dollars) server estimate. Pricing may be placeholder.",
                            isCurrent: standing.user_id == backend.identity?.userID)
                    }
                } else {
                    Eyebrow(text: "Members · not ranked")
                    ForEach(league.members) { member in
                        ChampionshipRow(rank: nil, name: member.nickname, result: "Not ranked", detail: "League needs 4+ members", isCurrent: member.user_id == backend.identity?.userID)
                    }
                }
            } else if !backend.isRemote {
                Surface {
                    DemoNotice()
                    Text("Example individual standings").font(DS.section)
                    Text("Fictional 4-driver league · no server or competition data").font(.caption).foregroundStyle(DS.secondary)
                }
                ForEach(Array([("Alex", 24), ("Sam", 21), ("Jordan", 17), ("Taylor", 12)].enumerated()), id: \.offset) { index, driver in
                    ChampionshipRow(rank: index + 1, name: driver.0, result: "\(driver.1)% improvement", detail: "Fictional driver · demonstration only", isCurrent: false)
                }
            } else {
                Surface {
                    Text("Your league starts here.").font(DS.section)
                    Text("Create a private league or paste an invitation from a friend. A league needs 4+ members for ranked standings.").foregroundStyle(DS.secondary)
                    QualificationMarks(memberCount: 0)
                }
            }
            Surface {
                Text("Walking Tests, demo replays, and synthetic trips are excluded from real competition. Each driver competes against other members of their private league.").font(.caption).foregroundStyle(DS.secondary)
            }
            NavigationLink("API & Vehicle setup") { APISettingsView() }.font(.subheadline)
            BackendStatusView()
        }.navigationTitle("Leagues").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { ProfileView() } label: { Text("PROFILE").font(DS.technical) } } }
            .refreshable { await backend.refreshLeague() }
            .task { if backend.identity != nil { await backend.refreshLeague() } }
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
            Text(detail).font(.caption).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Text("You will join automatically. Four members are required for ranked play.").font(.caption).foregroundStyle(DS.secondary)
                    Button("Create League") { Task { await backend.createLeague(name: name) } }.accessibilityIdentifier("createLeague")
                } else {
                    TextField("Paste full invitation", text: $invitation, axis: .vertical).accessibilityIdentifier("leagueInvitation")
                        .onChange(of: invitation) { _, value in
                            if let invite = LeagueInvitation.parse(value) { leagueID = invite.id.uuidString; inviteCode = invite.code }
                        }
                    Text("Paste your friend’s shared invitation above, or enter both details below.").font(.caption).foregroundStyle(DS.secondary)
                    TextField("League UUID", text: $leagueID).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("leagueUUID")
                    TextField("Invite code", text: $inviteCode).textInputAutocapitalization(.characters).autocorrectionDisabled().accessibilityIdentifier("leagueCode")
                    Text("Enter both values from the shared invite. The API cannot look up a league using only its code. Joining moves you out of your previous league.").font(.caption).foregroundStyle(DS.secondary)
                    Button("Join League") { Task { await backend.joinLeague(id: leagueID, code: inviteCode) } }.accessibilityIdentifier("joinLeague")
                }
            }.buttonStyle(IgnitionButtonStyle()).disabled(backend.isBusy)
            if let league = backend.league { Text("Current league: \(league.name)").font(.headline).foregroundStyle(DS.mint) }
            NavigationLink("Your profile") { ProfileView() }
            BackendStatusView()
        }.navigationTitle(creating ? "Create League" : "Join League").navigationBarTitleDisplayMode(.inline)
    }
}
