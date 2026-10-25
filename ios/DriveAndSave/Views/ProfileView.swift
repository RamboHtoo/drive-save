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
                DisplayType("Welcome.", size: 48)
                Surface {
                    Text("Your driver name").font(.title2.bold())
                    TextField("Nickname", text: $nickname).textContentType(.nickname)
                        .autocorrectionDisabled().submitLabel(.done).focused($editingNickname)
                        .accessibilityIdentifier("welcomeNickname")
                        .onSubmit { editingNickname = false }
                    Text("1–32 characters · visible to your league.").font(.caption).foregroundStyle(DS.secondary)
                    DisclosureGroup("Developer options") {
                        Toggle("Offline demo", isOn: $offline).accessibilityIdentifier("offlineOnboarding")
                        Text(offline ? "This iPhone only · no multiplayer" : "Online · account saved on this iPhone")
                            .font(.caption).foregroundStyle(DS.secondary)
                        if !offline {
                            DisclosureGroup("Account recovery") {
                                Toggle("Demo account recovery", isOn: $allowRecovery)
                                Text("Allow a replacement demo account after a server reset. Previous trips and league membership may be lost.").font(.caption).foregroundStyle(DS.secondary)
                            }.font(.subheadline)
                        }
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
                if backend.errorMessage != nil { Text("We couldn’t create your profile. Check your connection and try again.").font(.subheadline).foregroundStyle(.orange) }
                Text("Set up and review Drive Save only while safely stopped.").font(.footnote).foregroundStyle(DS.secondary)
            }
            .navigationTitle("Drive Save").navigationBarTitleDisplayMode(.inline)
            .onAppear { offline = !backend.isRemote }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var presentation: PresentationState
    @EnvironmentObject private var backend: BackendViewModel
    @AppStorage("developerMode") private var developerMode = false
    var body: some View {
        Screen {
            PresentationModeControl()
            if presentation.isEnabled {
                SampleProfileSummary()
            } else {
            DisplayType(backend.identity?.nickname ?? "No account", size: 44).accessibilityIdentifier("profileNickname")
            if !backend.isRemote { Text("Offline demo · this iPhone only").font(.caption).foregroundStyle(DS.secondary) }
            Surface {
                Eyebrow(text: "League")
                if let league = backend.league {
                    Text(league.name).font(DS.section)
                    Text("\(league.member_count) \(league.member_count == 1 ? "member" : "members") · \(league.canRank ? "Ranked" : "4 needed to rank")").foregroundStyle(DS.secondary)
                    LeagueInviteActions(league: league)
                } else { Text("No league joined").foregroundStyle(DS.secondary) }

            }
            Surface {
                Eyebrow(text: "My Vehicle")
                if let row = backend.vehicle {
                    Text(row.vehicleTitle).font(.headline).accessibilityIdentifier("profileVehicleTitle")
                    if let vehicle = try? CatalogVehicle(row: row), let mpg = vehicle.details.mpg.combined {
                        Text("\(mpg.formatted()) MPG combined").font(.subheadline).foregroundStyle(DS.secondary)
                    }
                    if !backend.vehicleConfirmed { Text("Example · unconfirmed").font(.caption).foregroundStyle(DS.secondary) }
                    if row["supported"] == .bool(false) { Text("Fuel estimates unavailable").font(.caption).foregroundStyle(.orange) }
                } else { Text("No vehicle selected").foregroundStyle(DS.secondary) }
                NavigationLink("My Vehicle") { MyVehicleView() }.accessibilityIdentifier("myVehicle")
            }
            }
            Surface {
                Eyebrow(text: "Developer Mode")
                Toggle("Enable developer tools", isOn: $developerMode).accessibilityIdentifier("developerMode")
                if developerMode {
                    NavigationLink("Developer tools") { APISettingsView() }.accessibilityIdentifier("openAdvancedSettings")
                    Text("Demo calculations, connection settings, and recording tests.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
        }
        .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
        .task { if !presentation.isEnabled { await backend.refreshLeague(); await backend.refreshMyVehicle() } }
    }
}

/// Explicit test-account controls belong with diagnostics, away from everyday profile details.
struct AccountAdvancedSettings: View {
    @EnvironmentObject private var backend: BackendViewModel
    @State private var confirmingReset = false
    var body: some View {
        Surface {
            Eyebrow(text: "Account")
            if let identity = backend.identity {
                Text("Signed in as \(identity.nickname)").font(.headline)
                Text("User ID: \(identity.userID.uuidString)").font(.caption.monospaced()).foregroundStyle(DS.secondary)
                    .textSelection(.enabled).accessibilityIdentifier("profileUserID")
            }
            Text("Accounts are saved separately for online and offline mode on this iPhone.").font(.caption).foregroundStyle(DS.secondary)
            Button("Reset test account…", role: .destructive) { confirmingReset = true }
                .accessibilityIdentifier("resetTestAccount").disabled(backend.isBusy)
        }
        .alert("Reset this device’s test sign-in?", isPresented: $confirmingReset) {
            Button("Reset sign-in & choose a new nickname", role: .destructive) { Task { await backend.resetAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This creates a different account next time you register. Your previous server account is not renamed or deleted. Local trips stay on this iPhone. You cannot recover the old sign-in with its nickname.") }
    }
}

struct LeagueInviteActions: View {
    let league: APILeague
    @State private var copied = false
    private var invitation: String { "Join my Drive Save league: \(league.name)\nLeague ID: \(league.crew_id.uuidString)\nInvite code: \(league.join_code ?? "")" }
    var body: some View {
        if league.join_code != nil {
            ViewThatFits(in: .horizontal) {
                HStack { inviteButtons }
                VStack(alignment: .leading) { inviteButtons }
            }.buttonStyle(.bordered)
        }
    }
    private var inviteButtons: some View {
        Group {
            Button(copied ? "Invite copied" : "Copy invite") { UIPasteboard.general.string = invitation; copied = true }
            ShareLink(item: invitation) { Label("Invite", systemImage: "square.and.arrow.up") }
        }
    }
}
