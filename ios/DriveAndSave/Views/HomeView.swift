import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    var body: some View {
        Screen {
            HStack { Text("Drive Save").font(.headline).foregroundStyle(DS.secondary); Spacer(); Image(systemName: "leaf.circle.fill").font(.title).foregroundStyle(DS.mint) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Small shifts.\nReal possibilities.").font(.system(size: 36, weight: .bold, design: .rounded)).tracking(-1)
                Text("Make every mile a little less wasteful.").foregroundStyle(DS.secondary)
            }
            NavigationLink { TripRecordingView() } label: {
                Label("Start Trip", systemImage: "record.circle")
                    .font(.headline).frame(maxWidth: .infinity).padding(18)
                    .foregroundStyle(DS.background).background(DS.mint, in: RoundedRectangle(cornerRadius: 18))
            }.accessibilityIdentifier("startTrip")
            NavigationLink { ProfileView() } label: { Label("Profile", systemImage: "person.crop.circle.fill") }.accessibilityIdentifier("openProfile")
            NavigationLink { APISettingsView() } label: { Label("API & Vehicle", systemImage: "person.crop.circle") }
            if model.client.isMock { DemoNotice(); Text("Cost totals use demo trips. New recordings show estimate pending.").font(.caption).foregroundStyle(DS.secondary) }
            Surface {
                Label("YOUR OPPORTUNITY", systemImage: "arrow.up.right").font(.caption.bold()).tracking(1.5).foregroundStyle(DS.mint)
                Text(model.avoidableCost.dollars).font(.system(size: 58, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text("Modeled avoidable fuel cost").font(.headline)
                Text("Across the demo trips. Smoother driving could reduce some of this cost; savings are not guaranteed.").font(.subheadline).foregroundStyle(DS.secondary)
                Divider().overlay(.white.opacity(0.1))
                HStack { Metric(value: "\(model.estimatedTrips.count)", label: "sample trips"); Metric(value: String(format: "%.1f", model.miles), label: "demo miles") }
            }
            NavigationLink { CrewLeaderboardView() } label: {
                Surface {
                    HStack { Image(systemName: "bolt.shield.fill").foregroundStyle(DS.mint); Text("Your private league").font(.headline); Spacer(); Image(systemName: "arrow.up.right") }
                    Text("Drivers compete individually inside a private league.").font(.subheadline).foregroundStyle(DS.secondary)
                    Text("OPEN LEAGUES →").font(.caption.bold()).tracking(1).foregroundStyle(DS.mint)
                }
            }.buttonStyle(.plain)
            HStack { Text("Recent drives").font(.title2.bold()); Spacer(); NavigationLink("View all") { TripHistoryView() }.font(.subheadline.bold()) }
            Surface {
                if model.drivingTrips.isEmpty { Text("Your trips will appear here.").foregroundStyle(DS.secondary) }
                ForEach(model.drivingTrips.prefix(3)) { trip in
                    NavigationLink { TripReceiptView(trip: trip) } label: { TripRow(trip: trip) }.buttonStyle(.plain)
                }
            }
            Label("Set up and review trips only when safely parked.", systemImage: "checkmark.shield").font(.footnote).foregroundStyle(DS.secondary)
        }.navigationBarTitleDisplayMode(.inline)
    }
}
