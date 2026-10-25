import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var presentation: PresentationState
    @EnvironmentObject private var backend: BackendViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Screen {
            PresentationModeControl()
            if presentation.isEnabled {
                SampleHomeDashboard()
            } else {
            VStack(alignment: .leading, spacing: 10) {
                if backend.isRemote {
                    Eyebrow(text: "Estimated savings · this week").accessibilityAddTraits(.isHeader).accessibilityIdentifier("homeHeadline")
                    FinancialNumber(value: backend.progress.flatMap { $0.hasSavings ? $0.est_savings_usd.receiptDollars : nil } ?? "—").accessibilityIdentifier("homeFinancialValue")
                    Text("Experimental estimate").font(.caption).foregroundStyle(DS.secondary)
                    if backend.progressError != nil {
                        Text("Progress unavailable").font(.headline)
                        Text("Check your connection and try again.").font(.caption).foregroundStyle(DS.secondary).accessibilityIdentifier("progressError")
                        Button("Retry") { Task { if !presentation.isEnabled { await backend.refreshProgress() } } }
                    } else if let progress = backend.progress {
                        if !progress.hasSavings {
                            Text(progress.availability).font(.subheadline).foregroundStyle(DS.secondary).accessibilityIdentifier("progressEmptyState")
                        }
                    } else if backend.isRefreshingProgress {
                        ProgressView("Loading progress…")
                    }
                } else {
                    Eyebrow(text: "Offline demo · fuel cost").accessibilityAddTraits(.isHeader).accessibilityIdentifier("homeHeadline")
                    FinancialNumber(value: model.estimatedTrips.isEmpty ? "—" : model.avoidableCost.dollars).accessibilityIdentifier("homeFinancialValue")
                    DemoNotice()
                    Text(model.estimatedTrips.isEmpty ? "No priced trips yet." : "Sample estimate · not measured waste or savings.").font(.subheadline).foregroundStyle(DS.secondary)
                }
            }
            NavigationLink { TripRecordingView() } label: {
                HStack { Text("Start Drive"); Spacer(); Text("↗").font(.title2) }
            }.buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("startTrip")
            Text("Set up and review trips only when safely parked.").font(.footnote).foregroundStyle(DS.secondary)
            }
        }
        .task(id: backend.progressContext) { if !presentation.isEnabled { await backend.refreshProgress() } }
        .refreshable { if !presentation.isEnabled { await backend.refreshProgress() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { if !presentation.isEnabled { await backend.refreshProgress() } } } }
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
