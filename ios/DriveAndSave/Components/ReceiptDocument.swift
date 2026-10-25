import SwiftUI

private struct ReceiptEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero); p.addLine(to: CGPoint(x: rect.maxX - 14, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 14)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 6))
        let count = max(1, Int(rect.width / 14))
        let step = rect.width / CGFloat(count)
        for i in (0..<count).reversed() {
            p.addLine(to: CGPoint(x: CGFloat(i) * step + step / 2, y: rect.maxY))
            p.addLine(to: CGPoint(x: CGFloat(i) * step, y: rect.maxY - 6))
        }
        p.closeSubpath(); return p
    }
}

struct ReceiptPaper<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20).padding(.bottom, 10)
            .foregroundStyle(DS.background).background(DS.ink, in: ReceiptEdge())
    }
}

struct ReceiptLedgerLine: View {
    let label: String
    let value: String
    var emphasized = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { description; Spacer(minLength: 8); amount }
            VStack(alignment: .leading, spacing: 6) { description; amount }
        }.font(.subheadline).padding(.vertical, 5)
    }
    private var description: some View { Text(label).foregroundStyle(emphasized ? DS.ink : DS.secondary) }
    private var amount: some View { Text(value).font(.body.monospaced().weight(.semibold)).foregroundStyle(emphasized ? DS.acid : DS.ink) }
}

/// Existing server response fields rendered as a document, without recalculating prices.
struct BackendReceiptCard: View {
    let receipt: APIReceipt
    let mock: Bool
    var showDetailsLink = true
    var syntheticCalculation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ReceiptPaper {
                Text(mock ? "OFFLINE MOCK RECEIPT" : "SERVER RECEIPT").font(DS.technical)
                if receipt.is_demo { Text("DEMO · EXCLUDED FROM REAL COMPETITION").font(.caption.weight(.bold)) }
                if receipt.cost_model == "flat_per_event" {
                    Text("PLACEHOLDER PRICING").font(.headline).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(DS.background).frame(height: 2) }
                    Text("Per-event placeholder · not measured fuel waste or savings.").font(.subheadline)
                }
                if syntheticCalculation {
                    Text("Vehicle used for pricing").font(.caption)
                    Text(receipt.vehicle ?? "Not reported by server").font(.headline).accessibilityIdentifier("calculationPricingVehicle")
                }
                FinancialNumber(value: syntheticCalculation ? receipt.avoidable_cost_usd.formatted(.currency(code: "USD").precision(.fractionLength(2...4))) : receipt.avoidable_cost_usd.dollars, ink: DS.background)
                Text(syntheticCalculation ? "Estimated avoidable fuel cost" : receipt.is_estimate ? "Estimated cost" : "Returned cost").font(.headline)
                if let label = receipt.label { Text(label).font(.subheadline) }
                else if syntheticCalculation { Text("Estimate · accuracy not validated").font(.subheadline) }
                if syntheticCalculation { Text("Model: \(receipt.cost_model)").font(.caption.monospaced()).accessibilityIdentifier("calculationModel") }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("serverReceiptDocument")
            if let highSpeedCost = receipt.high_speed_cost_usd { ReceiptLedgerLine(label: "High-speed portion", value: highSpeedCost.dollars) }
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "Event costs")
                if receipt.events.isEmpty { Text("No priced events returned.").foregroundStyle(DS.secondary) }
                ForEach(Array(receipt.events.enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: 8) {
                        ReceiptLedgerLine(label: event.type == "harsh_brake" ? "Harsh braking" : event.type == "rapid_accel" ? "Rapid acceleration" : event.type == "sharp_turn" ? "Sharp turn" : event.type, value: event.cost_usd.dollars)
                        Text("\(event.ts.formatted(date: .omitted, time: .standard)) · \(event.speed_before_mph, specifier: "%.1f") → \(event.speed_after_mph, specifier: "%.1f") mph").font(.caption.monospaced()).foregroundStyle(DS.secondary)
                        MeasurementRule()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup("Pricing assumptions") {
                ForEach(Array(receipt.assumptions.enumerated()), id: \.offset) { _, assumption in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(assumption.key.replacingOccurrences(of: "_", with: " ").capitalized): \(assumption.value.formatted()) \(assumption.unit)").font(.subheadline.weight(.semibold))
                        Text("As of \(assumption.as_of) · \(assumption.is_estimate ? "team estimate" : "published input")").font(.subheadline).foregroundStyle(DS.secondary)
                        if let source = assumption.source_url, let url = URL(string: source), ["https", "http"].contains(url.scheme ?? "") { Link("Source", destination: url) }
                        MeasurementRule()
                    }
                }
                    ForEach(receipt.notes ?? [], id: \.self) { note in Text(note).font(.caption).foregroundStyle(DS.secondary) }
                }.accessibilityIdentifier("pricingAssumptions")
                if showDetailsLink {
                    NavigationLink("Advanced Settings") { Screen { ReceiptServerDetails(receipt: receipt) }.navigationTitle("Advanced Settings").navigationBarTitleDisplayMode(.inline) }
                }
            }
        }
    }
}

struct ReceiptServerDetails: View {
    let receipt: APIReceipt
    var body: some View {
        Surface {
            Eyebrow(text: "Server details")
            Text("cost_model: \(receipt.cost_model)")
            Text("is_estimate: \(receipt.is_estimate ? "true" : "false")")
            Text("Server distance: \(receipt.distance_mi, specifier: "%.2f") mi")
            Text("Trip ID: \(receipt.trip_id.uuidString)").textSelection(.enabled)
        }.font(.caption.monospaced())
    }
}
