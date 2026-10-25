import SwiftUI

struct TripReceiptView: View {
    let trip: Trip
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Screen {
            if trip.isWalkingTest {
                Eyebrow(text: "Walking Test · GPS only")
            } else if trip.source == .simulated { DemoNotice() }
            else { Eyebrow(text: "Recorded · device sensors") }
            VStack(alignment: .leading, spacing: 8) {
                DisplayType(trip.displayTitle, size: 40).accessibilityAddTraits(.isHeader)
                Text(trip.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(DS.secondary)
            }
            if let receipt = backend.receipt(for: trip) {
                BackendReceiptCard(receipt: receipt, mock: !backend.isRemote, showDetailsLink: false)
            } else {
                ReceiptPaper {
                    Text(trip.isWalkingTest ? "WALKING TEST / GPS ONLY" : trip.hasEstimate ? "LOCAL / SIMULATED ESTIMATE" : "LOCAL / UNPRICED RECORDING").font(DS.technical)
                    if trip.hasEstimate { FinancialNumber(value: trip.avoidableCost.dollars, ink: DS.background) }
                    else { Text(trip.isWalkingTest ? "No fuel estimate" : "Estimate pending").font(.largeTitle.weight(.bold)).fontWidth(.condensed) }
                    if trip.hasEstimate {
                        Text("Estimated avoidable fuel cost").font(.headline)
                        Text("Sample data · not measured waste or savings.").font(.subheadline)
                    } else if trip.isWalkingTest {
                        Text("Excluded from driving costs and rankings.").font(.subheadline)
                    } else {
                        Text("No monetary savings claimed.").font(.subheadline)
                    }
                }
            }
            Surface {
                ReceiptLedgerLine(label: "Distance", value: trip.distanceLabel)
                ReceiptLedgerLine(label: "Duration", value: trip.durationLabel)
                if trip.measurementsIncomplete {
                    Label("Incomplete measurements", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let recording = trip.recording {
                    Text(recording.distanceAvailable ? (recording.distanceIsPartial ? "Partial GPS distance · gaps excluded" : "GPS distance estimate") : "GPS distance unavailable")
                        .font(.caption).foregroundStyle(DS.secondary)
                    if !trip.isWalkingTest, let status = recording.detectionStatus { Text(status).font(.caption).foregroundStyle(DS.secondary) }
                    ForEach(recording.interruptions, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
            }
            TripTimeline(trip: trip)
            if !trip.isWalkingTest {
                Surface {
                    Eyebrow(text: "Driving moments")
                    ReceiptLedgerLine(label: "Harsh braking", value: eventValue(trip.harshBraking))
                    ReceiptLedgerLine(label: "Rapid acceleration", value: eventValue(trip.rapidAcceleration))
                    ReceiptLedgerLine(label: "Sharp turns", value: eventValue(trip.sharpTurns))
                    Text("Candidate events · not confirmed unsafe driving. Road conditions and sensor noise affect detection.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            DisclosureGroup("Assumptions") {
                VStack(alignment: .leading, spacing: 16) {
                    if trip.hasEstimate {
                        ReceiptLedgerLine(label: "Baseline fuel", value: trip.baselineFuelCost.dollars)
                        ReceiptLedgerLine(label: "Modeled excess fuel", value: trip.avoidableCost.dollars)
                        ReceiptLedgerLine(label: "Estimated total", value: trip.totalFuelCost.dollars, emphasized: true)
                        Text("Baseline = distance ÷ \(trip.mpg, specifier: "%.0f") MPG × \(trip.fuelPrice.dollars)/gallon. Excess = \(trip.modeledExcessGallons, specifier: "%.3f") modeled gallons × fuel price.")
                        Text("Simulated inputs and illustrative excess fuel. No actual savings measured. Fuel only; excludes maintenance, insurance, and depreciation.")
                    } else if trip.isWalkingTest {
                        Text("GPS distance and time only. No driving events or fuel estimates. GPS accuracy varies; this is not a validated fitness tracker.")
                    } else {
                        Text("Phone sensors do not measure fuel use, brake wear, or insurance costs. GPS distance and candidate events are not independently validated.")
                        if trip.source == .simulated { Text("Synthetic motion and GPS samples · no iPhone sensor measurements.") }
                    }
                }.font(.subheadline).foregroundStyle(DS.secondary).padding(.top, 12)
            }
            if !trip.isWalkingTest { TripUploadSection(trip: trip) }
            NavigationLink("Advanced Settings") { TripReceiptAdvancedView(trip: trip) }.accessibilityIdentifier("receiptAdvancedSettings")
        }.navigationTitle(trip.isWalkingTest ? "Walking Test" : "Trip receipt").navigationBarTitleDisplayMode(.inline)
    }
    private func eventValue(_ count: Int) -> String { trip.recording?.motionAvailable == false ? "Unavailable" : "\(count)" }
}

struct TripReceiptAdvancedView: View {
    let trip: Trip
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Screen {
            Surface {
                Eyebrow(text: "Recording details")
                Text("Local ID: \((trip.clientTripID ?? trip.id).uuidString)").textSelection(.enabled)
                Text("Started: \(trip.date.formatted())")
                if let recording = trip.recording {
                    Text("Ended: \(recording.endedAt.formatted())")
                    if let accuracy = recording.gpsAccuracyMeters { Text("Last GPS accuracy: ±\(accuracy, specifier: "%.0f") m") }
                    if trip.isWalkingTest { Text("Driving detection disabled · no calibration needed") }
                    else {
                        Text(recording.detectionStatus ?? (recording.motionAvailable ? "Candidate events from calibrated motion. Zero does not prove smooth driving." : "Motion unavailable or uncalibrated."))
                        Text(recording.calibrationDescription)
                        if let valid = recording.calibrationValidAtEnd { Text(valid ? "Calibration valid at end" : "Calibration invalid at end") }
                    }
                }
            }.font(.caption)
            if let receipt = backend.receipt(for: trip) {
                ReceiptServerDetails(receipt: receipt)
            }
            if let payload = try? TripUploadBuilder.payload(for: trip), let data = try? APIJSON.encoder().encode(payload), let json = String(data: data, encoding: .utf8) {
                ShareLink(item: json, subject: Text("Drive Save API trip JSON")) { Label("Export API JSON", systemImage: "square.and.arrow.up") }
                Text("Contract payload · no coordinates or monetary inputs.").font(.caption).foregroundStyle(DS.secondary)
            }
        }.navigationTitle("Advanced Settings").navigationBarTitleDisplayMode(.inline)
    }
}
