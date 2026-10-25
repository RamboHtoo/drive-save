import SwiftUI

struct CrewLeaderboardView: View {
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Screen {
            Label(backend.isRemote ? "Online multiplayer · \(backend.identity?.nickname ?? "Driver")" : "Offline demo · no multiplayer", systemImage: backend.isRemote ? "network" : "iphone").font(.caption).foregroundStyle(DS.mint)
            Eyebrow(text: "Your private league")
            Text("Less waste.\nMore bragging rights.").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Compete individually with drivers in your league. A league needs 4+ members for ranked standings.").foregroundStyle(DS.secondary)
            HStack {
                NavigationLink("Create League") { LeagueFormView(creating: true) }
                NavigationLink("Join League") { LeagueFormView(creating: false) }
            }.buttonStyle(.borderedProminent)
            NavigationLink("API & Vehicle setup") { APISettingsView() }
            if let league = backend.league {
                Surface {
                    Text(league.name).font(.title2.bold())
                    if league.is_demo { DemoNotice() }
                    Text("\(league.member_count) members · \(league.canRank ? "Ranked league" : "Unranked — needs 4+ members")").foregroundStyle(DS.mint)
                    Text("League ID: \(league.crew_id.uuidString)").font(.caption).textSelection(.enabled)
                    LeagueInviteActions(league: league)
                    Button("Refresh league & drivers") { Task { await backend.refreshLeague() } }.disabled(backend.isBusy)
                }
                if league.canRank {
                    Text("Individual driver rankings").font(.title2.bold())
                    if backend.standings.isEmpty { Text("No ranked driving data yet. Baselines need the first 3 eligible trips.").foregroundStyle(DS.secondary) }
                    ForEach(backend.standings) { standing in
                        Surface {
                            HStack { Text(standing.rank.map { "#\($0)" } ?? "Unranked").font(.title2.bold()); Text(standing.nickname).font(.headline); Spacer(); Text(standing.improvement_pct.map { String(format: "%.1f%% improvement", $0) } ?? "Awaiting baseline").foregroundStyle(DS.mint) }
                            if backend.leaderboardIsDemo { DemoNotice() }
                            Text("\(standing.est_savings_usd.dollars) server estimate · current pricing may be placeholder").font(.caption).foregroundStyle(DS.secondary)
                        }
                    }
                } else {
                    Surface {
                        Eyebrow(text: "Members · not ranked")
                        ForEach(league.members) { member in Text(member.nickname).font(.headline) }
                    }
                }
            } else if !backend.isRemote {
                Surface {
                    DemoNotice()
                    Text("Example individual standings").font(.headline)
                    Text("Fictional 4-driver league · no server or competition data").font(.caption).foregroundStyle(DS.secondary)
                    ForEach(Array([("Alex", 24), ("Sam", 21), ("Jordan", 17), ("Taylor", 12)].enumerated()), id: \.offset) { index, driver in
                        HStack { Text("#\(index + 1)"); Text(driver.0); Spacer(); Text("\(driver.1)% improvement").foregroundStyle(DS.mint) }.font(.subheadline)
                    }
                }
            } else {
                Text("Create or join a private league to view individual driver standings.").foregroundStyle(DS.secondary)
            }
            Surface {
                Text("Walking Tests, demo replays, and synthetic trips are excluded from real competition. Each driver competes against other members of their private league.").font(.caption).foregroundStyle(DS.secondary)
            }
            BackendStatusView()
        }.navigationTitle("Leagues").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { ProfileView() } label: { Label("Profile", systemImage: "person.crop.circle") } } }
            .refreshable { await backend.refreshLeague() }
            .task { if backend.identity != nil { await backend.refreshLeague() } }
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
            }.buttonStyle(.borderedProminent).disabled(backend.isBusy)
            if let league = backend.league { Text("Current league: \(league.name)").font(.headline).foregroundStyle(DS.mint) }
            NavigationLink("Your profile") { ProfileView() }
            BackendStatusView()
        }.navigationTitle(creating ? "Create League" : "Join League").navigationBarTitleDisplayMode(.inline)
    }
}
