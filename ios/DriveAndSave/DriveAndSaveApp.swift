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
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }
            NavigationStack { CrewLeaderboardView() }.tabItem { Label("Leagues", systemImage: "person.3.fill") }
            NavigationStack { TripHistoryView() }.tabItem { Label("History", systemImage: "chart.xyaxis.line") }
        }
        .toolbarBackground(DS.background, for: .tabBar)
        .task { await model.load() }
        .overlay { if model.isLoading && model.trips.isEmpty { ProgressView("Loading your drives…").padding(24).background(DS.card, in: RoundedRectangle(cornerRadius: 20)) } }
        .alert("Unable to load drives", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Retry") { Task { await model.load() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text(model.errorMessage ?? "") }
    }
}
