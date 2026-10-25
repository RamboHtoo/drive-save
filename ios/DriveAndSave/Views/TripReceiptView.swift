import SwiftUI

struct TripReceiptView: View {
    let trip: Trip
    @EnvironmentObject private var backend: BackendViewModel
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var deletionFailed = false
    @AppStorage("developerMode") private var developerMode = false
    private var uploadDiagnostics: RecordingUploadDiagnostics { backend.uploadDiagnostics(for: trip) }
    var body: some View {
        Screen {
            if trip.source == .measured && !trip.isWalkingTest { Eyebrow(text: "Recorded drive") }
            if trip.isWalkingTest { Eyebrow(text: "Walking Test · GPS only") }
            else if trip.source == .simulated { DemoNotice() }
            VStack(alignment: .leading, spacing: 8) {
                DisplayType(trip.displayTitle, size: 40).accessibilityAddTraits(.isHeader)
                Text(trip.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(DS.secondary)
            }
            if trip.recording != nil && !trip.isWalkingTest {
                Text(uploadDiagnostics.state.rawValue).font(.headline).foregroundStyle(DS.secondary)
                    .accessibilityIdentifier("tripUploadState")
            }
            if let receipt = backend.receipt(for: trip) {
                BackendReceiptCard(receipt: receipt, mock: !backend.isRemote, showDetailsLink: false)
            } else {
                ReceiptPaper {
                    Text("Estimated fuel impact").font(.headline)
                    if trip.hasEstimate { FinancialNumber(value: trip.avoidableCost.dollars, ink: DS.background) }
                    else { Text(trip.isWalkingTest ? "No fuel estimate" : trip.isIncompleteRecording ? "Incomplete recording" : trip.recording != nil ? uploadDiagnostics.state.rawValue : "Estimate pending").font(.largeTitle.bold()).fontWidth(.condensed).accessibilityIdentifier("receiptEstimateState") }
                    Text("Vehicle recorded: \(trip.recordingContext?.vehicle?.vehicleTitle ?? "Not recorded")").font(.subheadline)
                }
                if trip.hasEstimate {
                    ReceiptLedgerLine(label: "Baseline fuel", value: trip.baselineFuelCost.dollars)
                    ReceiptLedgerLine(label: "Estimated excess fuel", value: trip.avoidableCost.dollars)
                    ReceiptLedgerLine(label: "Estimated total fuel", value: trip.totalFuelCost.dollars, emphasized: true)
                }
                DisclosureGroup("How it’s calculated") {
                    if trip.hasEstimate {
                        Text("Baseline fuel cost uses distance, MPG, and fuel price. Estimated excess fuel uses the demo’s modeled gallons and fuel price.").padding(.top, 8)
                    } else {
                        Text(trip.isWalkingTest ? "Walking Tests record GPS distance and time only and are excluded from rankings." : "A fuel estimate requires sufficient trip measurements and a supported vehicle. Phone sensors do not measure fuel use.").padding(.top, 8)
                    }
                }.font(.subheadline).foregroundStyle(DS.secondary)
                Text(trip.hasEstimate ? "Experimental demo estimate; no actual fuel use or savings measured." : "Experimental estimates may differ from actual fuel use and costs.").font(.caption).foregroundStyle(DS.secondary)
            }
            Surface {
                ReceiptLedgerLine(label: "Distance", value: trip.distanceLabel)
                ReceiptLedgerLine(label: "Duration", value: trip.durationLabel)
                if trip.measurementsIncomplete {
                    Label("Incomplete measurements", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if trip.recording?.distanceIsPartial == true { Text("Partial GPS distance · gaps excluded").font(.caption).foregroundStyle(DS.secondary) }
            }
            if !trip.isWalkingTest && backend.receipt(for: trip) == nil { TripUploadSection(trip: trip) }
            if developerMode && trip.recording != nil {
                NavigationLink("Recording diagnostics") { TripReceiptAdvancedView(trip: trip) }
                    .accessibilityIdentifier("recordingDiagnostics")
            }
            if model.isLocalTrip(trip) {
                Button("Delete local recording", role: .destructive) { confirmingDeletion = true }
                    .accessibilityIdentifier("deleteLocalTrip")
            }
        }.navigationTitle(trip.isWalkingTest ? "Walking Test" : "Trip receipt").navigationBarTitleDisplayMode(.inline)
        .alert("Delete local recording?", isPresented: $confirmingDeletion) {
            Button("Delete from this iPhone", role: .destructive) {
                do { try model.deleteLocalTrip(trip); dismiss() }
                catch { deletionFailed = true }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the recording from this iPhone. Server receipts, uploaded trips, and league rankings will not change.")
        }
        .alert("Recording couldn’t be deleted", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) { }
        } message: { Text("Your recording is still saved. Please try again.") }
    }
}

struct TripReceiptAdvancedView: View {
    let trip: Trip
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Screen {
            RecordingDiagnosticSummary(trip: trip)
            TripTimeline(trip: trip)
            Surface {
                Eyebrow(text: "Recording details")
                Text("Local ID: \((trip.clientTripID ?? trip.id).uuidString)").textSelection(.enabled)
                Text("Started: \(trip.date.formatted())")
                Text("Driving events: \(trip.eventCountLabel)")
                if trip.hasEstimate {
                    Text("MPG: \(trip.mpg.formatted()) · Fuel price: \(trip.fuelPrice.dollars)/gallon")
                    Text("Modeled excess gallons: \(trip.modeledExcessGallons.formatted())")
                }
                if let recording = trip.recording {
                    Text("Ended: \(recording.endedAt.formatted())")
                    Text("Events complete: \(recording.eventsComplete.map(String.init) ?? "Unknown (legacy)")")
                    Text("Detector: \(recording.detectorVersion ?? "Unknown (legacy)")")
                    Text("Observed GPS-window detector coverage: \(recording.observedGPSWindowComplete.map(String.init) ?? "Unknown")")
                    if let quality = recording.gpsQuality {
                        Text("GPS startup: \(quality.startupSeconds.map(String.init(describing:)) ?? "No reliable fix") s")
                        Text("GPS trailing gap: \(quality.trailingSeconds.map(String.init(describing:)) ?? "Unknown") s; maximum interior gap: \(quality.maximumGapSeconds) s")
                    }
                    if let coverage = recording.detectorCoverage {
                        Text("Detector coverage: \(coverage.firstObservation.map(String.init(describing:)) ?? "none") to \(coverage.lastObservation.map(String.init(describing:)) ?? "none") uptime")
                        ForEach(coverage.failures, id: \.self) { Text($0) }
                    }
                    if let context = trip.recordingContext {
                        Text("Recording owner: \(context.ownerID.uuidString)")
                        Text("Recording account scope: \(context.accountScope)")
                        Text("Recording vehicle: \(context.vehicle?.vehicleTitle ?? "Not selected")")
                    }
                    if let accuracy = recording.gpsAccuracyMeters { Text("Last GPS accuracy: ±\(accuracy, specifier: "%.0f") m") }
                    if trip.isWalkingTest { Text("Driving detection disabled · no calibration needed") }
                    else {
                        Text(recording.detectionStatus ?? (recording.motionAvailable ? "Candidate events from calibrated motion. Zero does not prove smooth driving." : "Motion unavailable or uncalibrated."))
                        Text(recording.calibrationDescription)
                        if let valid = recording.calibrationValidAtEnd { Text(valid ? "Calibration valid at end" : "Calibration invalid at end") }
                    }
                }
            }.font(.caption)
            if let reason = backend.insufficientReason(for: trip) { Text(reason).font(.caption).textSelection(.enabled) }
            if let reason = backend.unsupportedReason(for: trip) { Text(reason).font(.caption) }
            else {
                Button("Upload / retry & fetch receipt") { Task { await backend.upload(trip: trip) } }
                    .buttonStyle(IgnitionButtonStyle()).disabled(backend.isBusy)
            }
            BackendStatusView()
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

/// Only hosted by Developer Mode routes. No sensor values or eligibility flags are changed here.
struct RecordingDiagnosticSummary: View {
    let trip: Trip
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        let diagnostics = backend.uploadDiagnostics(for: trip)
        let summary = diagnostics.summary(for: trip)
        Surface {
            Eyebrow(text: "Upload diagnostics")
            Text(summary).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("recordingUploadSummary")
            ShareLink(item: summary, subject: Text("Drive Save recording diagnostics")) {
                Label("Share diagnostic summary", systemImage: "square.and.arrow.up")
            }.accessibilityIdentifier("shareRecordingDiagnostics")
        }
    }
}
