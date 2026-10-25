import SwiftUI

struct SampleTripReceiptView: View {
    let trip: Trip
    private var preview: SampleTripReceipt { SampleTripReceipt(trip: trip) }
    var body: some View {
        Screen {
            Eyebrow(text: "Presentation preview")
            Text(preview.recordedDate.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline).foregroundStyle(DS.secondary)
            ReceiptPaper {
                Text("Estimated fuel impact").font(DS.technical).accessibilityIdentifier("sampleReceiptLabel")
                Text(SampleTripReceipt.vehicle).font(.title2.bold()).accessibilityIdentifier("sampleReceiptVehicle")
                FinancialNumber(value: SampleTripReceipt.total, ink: DS.background).accessibilityIdentifier("sampleReceiptTotal")
                Text("Illustrative avoidable fuel cost").font(.headline)
            }
            VStack(spacing: 0) {
                ReceiptLedgerLine(label: "Recorded distance", value: preview.distance).accessibilityIdentifier("sampleReceiptDistance")
                ReceiptLedgerLine(label: "Recorded duration", value: preview.duration).accessibilityIdentifier("sampleReceiptDuration")
            }
            if preview.partialDistance { Text("Partial GPS distance · gaps excluded").font(.caption).foregroundStyle(DS.secondary) }
            if preview.incompleteMeasurements { Text("Original recording has incomplete measurements.").font(.caption).foregroundStyle(DS.secondary) }
            Surface {
                Eyebrow(text: "Sample cost breakdown")
                ForEach(SampleTripReceipt.lines) { line in
                    ReceiptLedgerLine(label: line.label, value: line.amount)
                }
                MeasurementRule()
                ReceiptLedgerLine(label: "Estimated fuel impact", value: SampleTripReceipt.total, emphasized: true)
            }
            Text("Distance and duration come from this saved trip. Dollar amounts and category allocations are illustrative, not calculated from its sensor data. This preview is not included in actual or sample weekly totals.")
                .font(.caption).foregroundStyle(DS.secondary)
            DisclosureGroup("Sample vehicle details") {
                ForEach(SampleTripReceipt.vehicleDetails, id: \.0) { label, value in
                    ReceiptLedgerLine(label: label, value: value)
                }
                Text("Display reference only. The trip’s original vehicle snapshot is unchanged.").font(.caption).foregroundStyle(DS.secondary)
            }.font(.subheadline)
        }.navigationTitle("Sample receipt").navigationBarTitleDisplayMode(.inline)
    }
}
