import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    private var latestTrace: Trip? { model.drivingTrips.first { !($0.recording?.speedSamples ?? []).isEmpty } }
    var body: some View {
        Screen {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Avoidable fuel cost").accessibilityAddTraits(.isHeader).accessibilityIdentifier("homeHeadline")
                FinancialNumber(value: model.estimatedTrips.isEmpty ? "—" : model.avoidableCost.dollars).accessibilityIdentifier("homeFinancialValue")
                if model.estimatedTrips.isEmpty {
                    Text("No priced trips yet.").font(.subheadline).foregroundStyle(DS.secondary)
                } else {
                    DemoNotice()
                    Text("Sample estimate · not measured waste or savings.").font(.subheadline).foregroundStyle(DS.secondary)
                }
            }
            NavigationLink { TripRecordingView() } label: {
                HStack { Text("Start Trip"); Spacer(); Text("↗").font(.title2) }
            }.buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("startTrip")
            MeasurementRule()
            TelemetryGraphic(trip: latestTrace)
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
