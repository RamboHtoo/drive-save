import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var backend: BackendViewModel
    @State private var nickname = ""
    @State private var offline = false
    @State private var allowRecovery = false
    @FocusState private var editingNickname: Bool

    var body: some View {
        NavigationStack {
            Screen {
                Image(systemName: "leaf.circle.fill").font(.system(size: 60)).foregroundStyle(DS.mint)
                Eyebrow(text: "Welcome to Drive Save")
                Text("Waste less.\nDrive together.").font(.system(size: 38, weight: .bold, design: .rounded))
                Text("Choose a driver nickname, then create a private league or join your friends.").foregroundStyle(DS.secondary)
                Surface {
                    Text("What should we call you?").font(.title2.bold())
                    TextField("Nickname", text: $nickname).textContentType(.nickname)
                        .autocorrectionDisabled().submitLabel(.done).focused($editingNickname)
                        .accessibilityIdentifier("welcomeNickname")
                        .onSubmit { editingNickname = false }
                    Text("1–32 characters. Your league members will see this name.").font(.caption).foregroundStyle(DS.secondary)
                    Toggle("Offline demo", isOn: $offline).accessibilityIdentifier("offlineOnboarding")
                    Text(offline ? "Only this iPhone. No server requests or multiplayer. Demo data stays separate from your remote account." : "Online multiplayer · \(URL(string: backend.connectionURL)?.host ?? "your selected server"). Each iPhone gets its own secure account.")
                        .font(.subheadline).foregroundStyle(DS.secondary)
                    if !offline {
                        DisclosureGroup("Development options") {
                            Toggle("Demo account recovery", isOn: $allowRecovery)
                            Text("Optional: if the server rejects your token, register a replacement demo account and show a reset notice. Previous server trips and league membership may be lost.").font(.caption).foregroundStyle(DS.secondary)
                        }.font(.subheadline)
                    }
                    Button(offline ? "Continue with offline demo" : "Join Drive Save") {
                        editingNickname = false
                        Task {
                            if backend.isRemote == offline {
                                await backend.connect(remote: !offline, baseURL: backend.connectionURL)
                                guard backend.errorMessage == nil else { return }
                            }
                            if backend.identity == nil { await backend.register(nickname: nickname, demoAccount: allowRecovery) }
                        }
                    }
                    .buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("welcomeRegister")
                    .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nickname.trimmingCharacters(in: .whitespacesAndNewlines).count > 32 || backend.isBusy)
                }
                if backend.isBusy { ProgressView("Creating your profile…") }
                if let error = backend.errorMessage { Text(error).font(.subheadline).foregroundStyle(.orange).textSelection(.enabled) }
                Text("Set up and review Drive Save only while safely stopped.").font(.footnote).foregroundStyle(DS.secondary)
            }
            .navigationTitle("Drive Save").navigationBarTitleDisplayMode(.inline)
            .onAppear { offline = !backend.isRemote }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var backend: BackendViewModel
    @State private var confirmingReset = false
    var body: some View {
        Screen {
            Surface {
                Eyebrow(text: "Your driver profile")
                Text(backend.identity?.nickname ?? "No account").font(.largeTitle.bold()).accessibilityIdentifier("profileNickname")
                Text(backend.isRemote ? "Online multiplayer account" : "Offline demo account · this device only").foregroundStyle(DS.mint)
                if let identity = backend.identity {
                    Text("User ID: \(identity.userID.uuidString)").font(.caption).foregroundStyle(DS.secondary).textSelection(.enabled).accessibilityIdentifier("profileUserID")
                }
                Text("Your account is saved securely on this iPhone. A nickname is not a login; entering the same name on another phone creates a separate driver.").font(.subheadline).foregroundStyle(DS.secondary)
            }
            Surface {
                Eyebrow(text: "League membership")
                if let league = backend.league {
                    Text(league.name).font(.title2.bold())
                    Text("\(league.member_count) members · \(league.canRank ? "Ranked league" : "Needs 4+ for ranked play")").foregroundStyle(DS.mint)
                    LeagueInviteActions(league: league)
                } else {
                    Text("No league loaded. Create or join one in Leagues; refresh to check saved membership.").foregroundStyle(DS.secondary)
                }
                Button("Refresh membership") { Task { await backend.refreshLeague() } }.disabled(backend.isBusy)
            }
            Surface {
                Eyebrow(text: "Connection mode")
                Text(backend.isRemote ? "Friends on other iPhones use the online backend. Offline demo is separate and cannot connect to their league." : "You are using an offline demo. Switch to online multiplayer to join friends on other iPhones.").font(.subheadline).foregroundStyle(DS.secondary)
                Button(backend.isRemote ? "Switch to offline demo" : "Use online multiplayer") {
                    Task {
                        await backend.connect(remote: !backend.isRemote, baseURL: backend.connectionURL)
                        if backend.identity != nil { await backend.refreshLeague() }
                    }
                }.buttonStyle(.bordered).disabled(backend.isBusy)
                Text("Switching restores the saved account for that mode, or shows welcome registration. Neither account is renamed or replaced.").font(.caption).foregroundStyle(DS.secondary)
            }
            NavigationLink("Vehicle & advanced settings") { APISettingsView() }
            Surface {
                Eyebrow(text: "Development / test accounts")
                Text("A new nickname creates a new server account. Resetting removes this mode’s saved sign-in from this iPhone. It does not rename or delete the old server account, or erase local trip history. You cannot recover the old sign-in using its nickname.")
                    .font(.subheadline).foregroundStyle(DS.secondary)
                Button("Reset test account…", role: .destructive) { confirmingReset = true }
                    .accessibilityIdentifier("resetTestAccount").disabled(backend.isBusy)
            }
            BackendStatusView()
        }
        .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
        .task { await backend.refreshLeague() }
        .alert("Reset this device’s test sign-in?", isPresented: $confirmingReset) {
            Button("Reset sign-in & choose a new nickname", role: .destructive) { Task { await backend.resetAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This creates a different account next time you register. Your previous server account is not renamed or deleted. Local trips stay on this iPhone.") }
    }
}

struct LeagueInviteActions: View {
    let league: APILeague
    @State private var copied = false
    private var invitation: String { "Join my Drive Save league: \(league.name)\nLeague ID: \(league.crew_id.uuidString)\nInvite code: \(league.join_code ?? "")" }
    var body: some View {
        if let code = league.join_code {
            Text("Invite code: \(code)").font(.headline).textSelection(.enabled)
            HStack {
                Button(copied ? "Invite copied" : "Copy invite") { UIPasteboard.general.string = invitation; copied = true }
                ShareLink(item: invitation) { Label("Share invite", systemImage: "square.and.arrow.up") }
            }.buttonStyle(.bordered)
            Text("Share both the league ID and code. Friends can paste the full invitation in Join League.").font(.caption).foregroundStyle(DS.secondary)
        }
    }
}
