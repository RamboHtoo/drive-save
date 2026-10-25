import SwiftUI

struct TripReceiptView: View {
    let trip: Trip
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Screen {
            if trip.isWalkingTest {
                Label(trip.provenanceLabel, systemImage: "figure.walk").font(.caption.bold()).foregroundStyle(DS.mint)
            } else if trip.source == .simulated { DemoNotice() }
            else { Label("RECORDED · DEVICE SENSORS", systemImage: "sensor.fill").font(.caption.bold()).foregroundStyle(DS.mint) }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: trip.isWalkingTest ? "GPS test receipt" : "Your trip, itemized")
                DisplayType(trip.displayTitle, size: 40).accessibilityAddTraits(.isHeader)
                Text(trip.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(DS.secondary)
            }
            if let receipt = backend.receipt(for: trip) { BackendReceiptCard(receipt: receipt, mock: !backend.isRemote) }
            if backend.receipt(for: trip) == nil {
                ReceiptPaper {
                    Text(trip.isWalkingTest ? "WALKING TEST / GPS ONLY" : trip.hasEstimate ? "LOCAL / SIMULATED ESTIMATE" : "LOCAL / UNPRICED RECORDING").font(DS.technical)
                    if trip.hasEstimate { FinancialNumber(value: trip.avoidableCost.dollars, ink: DS.background) }
                    else { Text(trip.isWalkingTest ? "No fuel estimate" : "Estimate pending").font(.largeTitle.weight(.bold)).fontWidth(.condensed) }
                    Text(trip.isWalkingTest ? "Walking Test · excluded from driving and league rankings" : "Modeled avoidable fuel cost").font(.headline)
                    Text(trip.hasEstimate ? "Illustrative sample data. No actual savings were measured." : trip.isWalkingTest ? "GPS inputs and elapsed time only. No driving events or fuel costs." : "No monetary savings are claimed. An eligible API receipt is needed for model pricing.").font(.subheadline)
                    Text("LOCAL REF / \((trip.clientTripID ?? trip.id).uuidString)").font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            Surface {
                Eyebrow(text: "Local recording summary")
                ReceiptLedgerLine(label: "Distance", value: trip.distanceLabel)
                ReceiptLedgerLine(label: "Duration", value: trip.durationLabel)
                if !trip.isWalkingTest { ReceiptLedgerLine(label: "Candidate events", value: trip.eventCountLabel) }
            }
            TripTimeline(trip: trip)
            if trip.hasEstimate {
                Surface {
                    Eyebrow(text: "Fuel estimate")
                    receiptLine("Baseline fuel", value: trip.baselineFuelCost.dollars)
                    receiptLine("Modeled excess fuel", value: trip.avoidableCost.dollars)
                    Divider()
                    receiptLine("Estimated total", value: trip.totalFuelCost.dollars, emphasized: true)
                    Text("Fuel only. Excludes maintenance, insurance, and vehicle depreciation.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            if let recording = trip.recording {
                Surface {
                    Eyebrow(text: "Recording quality")
                    if trip.measurementsIncomplete {
                        Label("Incomplete measurements", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text(recording.distanceAvailable ? (recording.distanceIsPartial ? "Partial GPS distance; gaps were not filled." : "Filtered GPS distance estimate.") : "Distance unavailable. Not enough valid GPS points or permission was denied.")
                    if let accuracy = recording.gpsAccuracyMeters { Text("Last reported GPS accuracy: ±\(accuracy, specifier: "%.0f") m") }
                    if trip.isWalkingTest {
                        Text("Driving-event detection disabled by design. No motion sensors or calibration used.")
                    } else {
                        Text(recording.detectionStatus ?? (recording.motionAvailable ? "Candidate events from calibrated motion. Zero does not prove smooth driving." : "Candidate events unavailable: motion was unavailable or uncalibrated."))
                        if let valid = recording.calibrationValidAtEnd { Text(valid ? "Calibration valid at end of recording." : "Calibration not valid at end of recording.") }
                    }
                    Text("Started: \(trip.date.formatted())\nEnded: \(recording.endedAt.formatted())")
                    ForEach(recording.interruptions, id: \.self) { Text($0).foregroundStyle(.orange) }
                }.font(.subheadline)
            }
            if !trip.isWalkingTest {
                Surface {
                    Eyebrow(text: "Driving moments")
                    receiptLine("Candidate harsh braking", value: eventValue(trip.harshBraking))
                    receiptLine("Candidate rapid acceleration", value: eventValue(trip.rapidAcceleration))
                    receiptLine("Candidate sharp turns", value: eventValue(trip.sharpTurns))
                    Text("Candidate events do not establish unsafe driving. Road conditions and sensor noise can affect detection.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            Surface {
                Eyebrow(text: "Behind the numbers")
                if trip.isWalkingTest {
                    Text("Walking Test records real GPS inputs and elapsed time only. Fuel costs, driving-event detection, and league rankings are not applicable. GPS accuracy varies; this is not a validated fitness tracker.").font(.subheadline).foregroundStyle(DS.secondary)
                } else if trip.hasEstimate {
                    Text("Baseline = distance ÷ \(trip.mpg, specifier: "%.0f") MPG × \(trip.fuelPrice.dollars)/gallon. Excess = \(trip.modeledExcessGallons, specifier: "%.3f") modeled gallons × fuel price.").font(.subheadline).foregroundStyle(DS.secondary)
                    Text("All measurements and excess fuel on this demo receipt are simulated. Excess fuel is an illustrative input, not a validated physics model. No actual savings were measured.").font(.subheadline).foregroundStyle(DS.secondary)
                } else {
                    Text(backend.receipt(for: trip) != nil ? "The server receipt above contains model estimates. Phone sensors do not measure actual fuel use, brake wear, or insurance costs." : "Financial estimate pending the analytics API. Motion sensors do not measure actual fuel consumption, brake wear, or insurance costs. No monetary savings are claimed.").font(.subheadline).foregroundStyle(DS.secondary)
                    Text(trip.recording?.calibrationDescription ?? "").font(.caption).foregroundStyle(DS.secondary)
                    Text(trip.source == .simulated ? "This entire test recording uses synthetic motion and GPS samples, not iPhone sensor measurements." : "This foreground trip uses iPhone sensor inputs. GPS distance and candidate event classifications have measurement uncertainty and are not independently validated.").font(.subheadline).foregroundStyle(DS.secondary)
                }
            }
            if !trip.isWalkingTest { TripUploadSection(trip: trip) }
            if let payload = try? TripUploadBuilder.payload(for: trip), let data = try? APIJSON.encoder().encode(payload), let json = String(data: data, encoding: .utf8) {
                ShareLink(item: json, subject: Text("Drive Save API trip JSON")) {
                    Label("Export API JSON", systemImage: "square.and.arrow.up")
                }
                Text("Backend contract payload · no coordinates or monetary inputs.").font(.caption).foregroundStyle(DS.secondary)
            }
        }.navigationTitle(trip.isWalkingTest ? "Walking Test" : "Trip receipt").navigationBarTitleDisplayMode(.inline)
    }
    private func eventValue(_ count: Int) -> String { trip.recording?.motionAvailable == false ? "Unavailable" : "\(count)" }
    private func receiptLine(_ label: String, value: String, emphasized: Bool = false) -> some View {
        ReceiptLedgerLine(label: label, value: value, emphasized: emphasized)
    }
}
