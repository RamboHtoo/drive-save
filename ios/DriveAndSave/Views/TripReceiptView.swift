import SwiftUI

struct TripReceiptView: View {
    let trip: Trip
    var body: some View {
        Screen {
            if trip.source == .simulated { DemoNotice() }
            else { Label("RECORDED · DEVICE SENSORS", systemImage: "sensor.fill").font(.caption.bold()).foregroundStyle(DS.mint) }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Your trip, itemized")
                Text(trip.title).font(.largeTitle.bold())
                Text(trip.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(DS.secondary)
            }
            Surface {
                Image(systemName: "leaf.fill").font(.largeTitle).foregroundStyle(DS.mint)
                Text(trip.hasEstimate ? trip.avoidableCost.dollars : "Estimate pending").font(.system(size: trip.hasEstimate ? 52 : 30, weight: .bold, design: .rounded)).foregroundStyle(DS.mint)
                Text("Modeled avoidable fuel cost").font(.headline)
                HStack { Metric(value: trip.distanceLabel, label: "distance"); Metric(value: trip.durationLabel, label: "duration"); Metric(value: "\(trip.eventCount)", label: "candidate events") }
            }
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
                    Text(recording.distanceAvailable ? (recording.distanceIsPartial ? "Partial GPS distance; gaps were not filled." : "Filtered GPS distance estimate.") : "Distance unavailable. Not enough valid GPS points or permission was denied.")
                    Text(recording.motionAvailable ? "Candidate events from calibrated motion. Zero means none detected, not proof of smooth driving." : "Candidate events unavailable: motion was unavailable or uncalibrated.")
                    Text("Started: \(trip.date.formatted())\nEnded: \(recording.endedAt.formatted())")
                    ForEach(recording.interruptions, id: \.self) { Text($0).foregroundStyle(.orange) }
                }.font(.subheadline)
            }
            Surface {
                Eyebrow(text: "Driving moments")
                receiptLine("Candidate harsh braking", value: "\(trip.harshBraking)")
                receiptLine("Candidate rapid acceleration", value: "\(trip.rapidAcceleration)")
                receiptLine("Candidate sharp turns", value: "\(trip.sharpTurns)")
                Text("Candidate events do not establish unsafe driving. Road conditions and sensor noise can affect detection.").font(.caption).foregroundStyle(DS.secondary)
            }
            Surface {
                Label("Behind the numbers", systemImage: "info.circle").font(.headline)
                if trip.hasEstimate {
                Text("Baseline = distance ÷ \(trip.mpg, specifier: "%.0f") MPG × \(trip.fuelPrice.dollars)/gallon. Excess = \(trip.modeledExcessGallons, specifier: "%.3f") modeled gallons × fuel price.").font(.subheadline).foregroundStyle(DS.secondary)
                Text(trip.source == .simulated ? "All distance, duration, events, and excess fuel values on this receipt are simulated. Excess fuel is an illustrative input, not a validated physics model. No sensors were used, and no actual savings were measured." : "Distance and candidate events originate from recorded inputs. Fuel costs remain estimates and are not measured fuel consumption.").font(.subheadline).foregroundStyle(DS.secondary)
                } else {
                    Text("Financial estimate pending the analytics API. Motion sensors do not measure actual fuel consumption, brake wear, or insurance costs. No monetary savings are claimed.").font(.subheadline).foregroundStyle(DS.secondary)
                    Text(trip.recording?.calibrationDescription ?? "").font(.caption).foregroundStyle(DS.secondary)
                    Text(trip.source == .simulated ? "This entire test recording uses synthetic motion and GPS samples, not iPhone sensor measurements." : "This foreground trip uses iPhone sensor inputs. GPS distance and candidate event classifications have measurement uncertainty and are not independently validated.").font(.subheadline).foregroundStyle(DS.secondary)
                }
            }
        }.navigationTitle("Trip receipt").navigationBarTitleDisplayMode(.inline)
    }
    private func receiptLine(_ label: String, value: String, emphasized: Bool = false) -> some View {
        HStack { Text(label).foregroundStyle(emphasized ? .white : DS.secondary); Spacer(); Text(value).fontWeight(.semibold).foregroundStyle(emphasized ? DS.mint : .white) }.font(.subheadline)
    }
}
