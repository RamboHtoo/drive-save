import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var backend: BackendViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    private var latestTrace: Trip? { model.drivingTrips.first { !($0.recording?.speedSamples ?? []).isEmpty } }
    private var position: APIStanding? { backend.standings.first { $0.user_id == backend.identity?.userID } }
    var body: some View {
        Screen {
            DisplayType("LESS WASTE.\nMORE DRIVE.", size: 46).accessibilityAddTraits(.isHeader).accessibilityIdentifier("homeHeadline")
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "01 / Financial outlook")
                FinancialNumber(value: model.estimatedTrips.isEmpty ? "—" : model.avoidableCost.dollars).accessibilityIdentifier("homeFinancialValue")
                Text("Modeled avoidable fuel cost").font(.headline)
                if model.estimatedTrips.isEmpty {
                    Text("No priced trips yet. Recording a drive does not automatically produce a financial estimate.").font(.subheadline).foregroundStyle(DS.secondary)
                } else {
                    DemoNotice()
                    Text("Illustrative total across \(model.estimatedTrips.count) sample trips. Not measured fuel waste or achieved savings.").font(.subheadline).foregroundStyle(DS.secondary)
                }
            }
            NavigationLink { TripRecordingView() } label: {
                HStack { Text("Start Trip"); Spacer(); Text("↗").font(.title2) }
            }.buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("startTrip")
            Text("SET UP WHILE PARKED · FOREGROUND ONLY").font(DS.technical).foregroundStyle(DS.secondary)
            MeasurementRule()
            TelemetryGraphic(trip: latestTrace)
            Surface {
                Eyebrow(text: "03 / Your championship")
                NavigationLink { CrewLeaderboardView() } label: {
                    HStack(alignment: .top, spacing: 16) {
                        DisplayType(position?.rank.map { String(format: "%02d", $0) } ?? "—", size: 52)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(backend.league?.name ?? "Join the field").font(DS.section).foregroundStyle(DS.ink)
                            Text(backend.league == nil ? "Create a league. Invite your people." : position?.rank == nil ? "Awaiting baseline · individual standings" : "Your current individual position")
                                .font(.subheadline).foregroundStyle(DS.secondary)
                            Text(backend.isRemote ? "ONLINE LEAGUES →" : "OFFLINE DEMO · OPEN LEAGUES →").font(DS.technical).foregroundStyle(DS.acid)
                        }
                    }
                }.buttonStyle(.plain)
            }
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "04 / Recent drives")
                Spacer()
                NavigationLink("View all") { TripHistoryView() }.font(.subheadline).frame(minHeight: 44)
            }
            if model.drivingTrips.isEmpty {
                Text("Your first completed drive will appear here.").foregroundStyle(DS.secondary)
            }
            ForEach(model.drivingTrips.prefix(3)) { trip in
                NavigationLink { TripReceiptView(trip: trip) } label: { TripRow(trip: trip) }.buttonStyle(.plain)
            }
            NavigationLink("API & Vehicle") { APISettingsView() }.font(.subheadline).frame(minHeight: 44)
            Text("Set up and review trips only when safely parked.").font(.footnote).foregroundStyle(DS.secondary)
        }
        .safeAreaInset(edge: .top, spacing: 0) { masthead }
        .navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .navigationBar)
    }
    private var masthead: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { wordmark; profileLink }
            } else {
                HStack(alignment: .firstTextBaseline) { wordmark; Spacer(); profileLink }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
            .background(DS.background.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) { MeasurementRule() }
    }
    private var wordmark: some View { Text("Drive Save").font(.headline.weight(.black)).tracking(-0.5).foregroundStyle(DS.ink) }
    private var profileLink: some View {
        NavigationLink { ProfileView() } label: { Text("PROFILE ↗").font(DS.technical).frame(minHeight: 44).foregroundStyle(DS.ink) }
            .accessibilityIdentifier("openProfile")
    }

}
