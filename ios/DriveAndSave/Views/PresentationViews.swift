import SwiftUI

/// The same session-wide switch is accessible on each summary screen, outside Developer Mode.
struct PresentationModeControl: View {
    @EnvironmentObject private var presentation: PresentationState
    var leagueContext = false
    var body: some View {
        Toggle(isOn: $presentation.isEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Presentation Mode").font(.subheadline.weight(.semibold))
                Text(presentation.isEnabled ? "Sample data · illustrative results" : (leagueContext ? "Actual League · turn on for Sample League" : "Actual data · turn on for sample dashboard"))
                    .font(.caption).foregroundStyle(DS.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.tint(DS.acid).accessibilityIdentifier("presentationMode")
            .accessibilityHint("Switches Home, Leagues, Profile and History together. Your account stays unchanged.")
    }
}

struct SampleHomeDashboard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Sample data · this week").accessibilityIdentifier("sampleDataLabel")
            Text("Weekly estimated avoidable fuel cost").font(.headline)
            FinancialNumber(value: PresentationData.weeklyCost, ink: DS.acid).accessibilityIdentifier("sampleHomeCost")
            Text("\(PresentationData.presenter) · \(PresentationData.vehicle)").font(.subheadline).foregroundStyle(DS.secondary)
        }
        Surface {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { metrics }
                VStack(alignment: .leading, spacing: 20) { metrics }
            }
        }
        Surface {
            HStack(alignment: .firstTextBaseline) {
                Metric(value: PresentationData.presenterRank, label: "Sample league rank")
                Text("LOWEST COST").font(DS.technical).foregroundStyle(DS.acid)
            }
            Text(PresentationData.improvement).font(.headline)
            Text("Compared with the previous sample week. Improvement does not determine rank.").font(.caption).foregroundStyle(DS.secondary)
        }
        Text("Illustrative results, not recorded trips or measured savings.").font(.footnote).foregroundStyle(DS.secondary)
    }
    @ViewBuilder private var metrics: some View {
        Metric(value: "\(PresentationData.trips.count)", label: "Sample trips this week")
        Metric(value: PresentationData.weeklyDistance, label: "Sample miles this week")
    }
}

struct SampleLeagueStandings: View {
    var body: some View {
        DisplayType("Sample League", size: 48).accessibilityIdentifier("sampleLeagueHeadline")
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Illustrative results · 6 drivers")
            Text("Weekly estimated avoidable fuel cost").font(.headline)
            Text("Lowest cost ranks first.").font(.subheadline).foregroundStyle(DS.secondary)
        }
        VStack(spacing: 0) {
            ForEach(PresentationData.players) { player in
                ChampionshipRow(rank: PresentationData.rank(of: player), name: player.name,
                                result: player.cost, detail: player.isPresenter ? "Current presenter · sample data" : "",
                                isCurrent: player.isPresenter)
                    .accessibilityIdentifier(player.id)
            }
        }.accessibilityIdentifier("sampleStandings")
        Text("Fictional results. Your actual league, members and invite stay unchanged.").font(.footnote).foregroundStyle(DS.secondary)
    }
}

struct SampleProfileSummary: View {
    var body: some View {
        DisplayType(PresentationData.presenter, size: 44).accessibilityIdentifier("sampleProfileName")
        Eyebrow(text: "Sample profile · illustrative results")
        Surface {
            Eyebrow(text: "Sample vehicle")
            Text(PresentationData.vehicle).font(DS.section).accessibilityIdentifier("sampleProfileVehicle")
        }
        Surface {
            Eyebrow(text: "This sample week")
            Text(PresentationData.weeklyCost).font(.largeTitle.weight(.semibold)).foregroundStyle(DS.acid).accessibilityIdentifier("sampleProfileCost")
            Text("Estimated avoidable fuel cost").font(.subheadline)
            Text("\(PresentationData.trips.count) trips · \(PresentationData.weeklyDistance) miles").foregroundStyle(DS.secondary)
            Text("Sample league · \(PresentationData.presenterRank)").font(.headline)
            Text(PresentationData.improvement).font(.subheadline).foregroundStyle(DS.secondary)
        }
        Text("Display only. Your saved identity and vehicle have not changed.").font(.footnote).foregroundStyle(DS.secondary)
    }
}

struct SampleTripHistory: View {
    var body: some View {
        Eyebrow(text: "Sample data · 8 fictional trips")
        HStack {
            Text("\(PresentationData.weeklyDistance) miles").foregroundStyle(DS.secondary)
            Spacer()
            Text(PresentationData.weeklyCost).font(.title2.weight(.semibold)).foregroundStyle(DS.acid).accessibilityIdentifier("sampleHistoryCost")
        }
        Text("Estimated avoidable fuel cost · illustrative results, not financial receipts.").font(.caption).foregroundStyle(DS.secondary)
        ForEach(PresentationData.trips.reversed()) { trip in
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(trip.title).font(.headline); Spacer(); Text(trip.cost).monospacedDigit() }
                Text("\(trip.timeLabel) · \(trip.distance)").font(.caption).foregroundStyle(DS.secondary)
            }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { MeasurementRule() }.accessibilityIdentifier(trip.id)
        }
    }
}
