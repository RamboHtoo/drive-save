// xcode: set sdk=iOS

import SwiftUI

@main
struct DriveAndSaveApp: App {
    @StateObject private var model = AppViewModel()
    @StateObject private var backend = BackendViewModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(backend).preferredColorScheme(.dark).tint(DS.mint)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var backend: BackendViewModel
    @State private var selectedDestination: PrimaryDestination = .home
    var body: some View {
        Group {
            if backend.isRestoringAccount {
                ProgressView("Restoring your profile…").frame(maxWidth: .infinity, maxHeight: .infinity).background(DS.background)
            } else if backend.identity == nil {
                WelcomeView()
            } else {
                appTabs
            }
        }
        .task { await backend.restoreAccount() }
        .alert("Demo account recovered", isPresented: Binding(get: { backend.recoveryMessage != nil }, set: { if !$0 { backend.recoveryMessage = nil } })) {
            Button("Understood") { backend.recoveryMessage = nil }
        } message: { Text(backend.recoveryMessage ?? "") }
    }
    private var appTabs: some View {
        NavigationStack {
            Group {
                switch selectedDestination {
                case .home: HomeView()
                case .leagues: CrewLeaderboardView()
                case .history: TripHistoryView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PrimaryNavigation(selection: $selectedDestination) }
        }
        .task { await model.load() }
        .overlay { if model.isLoading && model.trips.isEmpty { ProgressView("Loading your drives…").padding(24).background(DS.card, in: RoundedRectangle(cornerRadius: 20)) } }
        .alert("Unable to load drives", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Retry") { Task { await model.load() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text(model.errorMessage ?? "") }
    }
}
