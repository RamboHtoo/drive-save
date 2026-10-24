import SwiftUI

struct CrewLeaderboardView: View {
    @EnvironmentObject private var model: AppViewModel
    var body: some View {
        Screen {
            if model.client.isMock { DemoNotice() }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "The weekly rivalry")
                Text("Less waste.\nMore bragging rights.").font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-0.8)
                Text("A little friendly competition goes a long way.").foregroundStyle(DS.secondary)
            }
            Surface {
                HStack { Image(systemName: "flag.checkered").foregroundStyle(DS.mint); Eyebrow(text: "This week's challenge") }
                Text("Find your smooth.").font(.title2.bold())
                Text("Reduce modeled excess fuel per mile by 15% against your crew’s previous week.").foregroundStyle(DS.secondary)
                ProgressView(value: 1).tint(DS.mint).accessibilityLabel("Demo challenge target achieved")
                HStack { Text("Nittany Cruisers · 21% reduction"); Spacer(); Image(systemName: "checkmark.seal.fill") }.font(.caption.bold()).foregroundStyle(DS.mint)
                Text("Sample challenge result · no live competition").font(.caption).foregroundStyle(DS.secondary)
            }
            HStack { Text("Crew standings").font(.title2.bold()); Spacer(); Text("DEMO WEEK").font(.caption2.bold()).foregroundStyle(DS.secondary) }
            VStack(spacing: 12) {
                ForEach(Array(model.crews.enumerated()), id: \.element.id) { index, crew in
                    Surface {
                        HStack(spacing: 14) {
                            Text(String(format: "%02d", index + 1)).font(.title3.monospacedDigit().bold()).foregroundStyle(DS.secondary)
                            Image(systemName: crew.symbol).font(.title2).foregroundStyle(DS.mint).frame(width: 30)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(crew.name).font(.subheadline.bold())
                                Text("\(crew.members) members\(crew.isYourCrew ? " · Your crew" : "")").font(.caption).foregroundStyle(DS.secondary)
                            }
                            Spacer(minLength: 0)
                            Text("−\(crew.reductionPercent, specifier: "%.0f")%").font(.title3.bold()).foregroundStyle(DS.mint)
                        }
                    }.overlay(RoundedRectangle(cornerRadius: 24).stroke(crew.isYourCrew ? DS.mint.opacity(0.6) : .clear))
                }
            }
            Surface {
                Label("A fairer kind of rivalry", systemImage: "person.3.sequence.fill").font(.headline)
                Text("Crews have 4+ members. Rankings compare percentage improvement in modeled excess fuel per mile against each crew’s own baseline, rather than total miles driven. These standings are fictional.").font(.subheadline).foregroundStyle(DS.secondary)
            }
        }.navigationTitle("Your crew").navigationBarTitleDisplayMode(.inline)
    }
}
