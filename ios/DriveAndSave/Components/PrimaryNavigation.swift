import SwiftUI

enum PrimaryDestination: String, CaseIterable {
    case home = "Home", leagues = "Leagues", history = "History"
}

/// Intrinsic-height rail inserted into the root's safe area, never painted over content.
struct PrimaryNavigation: View {
    @Binding var selection: PrimaryDestination
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 0) { ForEach(PrimaryDestination.allCases, id: \.self) { destination in navigationButton(destination, expanded: true) } }
            } else {
                HStack(alignment: .top, spacing: 0) { ForEach(PrimaryDestination.allCases, id: \.self) { destination in navigationButton(destination, expanded: false) } }
            }
        }.padding(.horizontal, 20).background(DS.background.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { MeasurementRule() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("primaryNavigation")
    }
    private func navigationButton(_ destination: PrimaryDestination, expanded: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) { selection = destination }
        } label: {
            title(destination)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 10)
                .padding(.leading, expanded ? 12 : 0)
                .overlay(alignment: expanded ? .leading : .top) {
                    if selection == destination { Rectangle().fill(DS.acid).frame(width: expanded ? 3 : nil, height: expanded ? nil : 2) }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(destination.rawValue)
            .accessibilityIdentifier("nav-\(destination.rawValue)")
            .accessibilityAddTraits(selection == destination ? .isSelected : [])
    }
    private func title(_ destination: PrimaryDestination) -> some View {
        Text(destination.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
    }

}
