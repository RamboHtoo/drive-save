import SwiftUI

struct TripRecordingView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = TripRecordingService()
    @State private var simulatorMode = false
    @State private var mountingConfirmed = false
    @State private var began = false
    @State private var receipt: Trip?
    @State private var pendingTrip: Trip?
    @State private var saveError: String?
    @State private var showDebug = false
    var body: some View {
        Screen {
            if let receipt {
                Label("Trip saved on this iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(DS.mint)
                NavigationLink { TripReceiptView(trip: receipt) } label: {
                    Label("Open trip receipt", systemImage: "receipt").font(.headline).frame(maxWidth: .infinity).padding()
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("openReceipt")
                Text("You can also find it in History.").foregroundStyle(DS.secondary)
            } else if began {
                recordingContent
            } else {
                setupContent
            }
        }
        .navigationTitle(receipt != nil ? "Trip saved" : began ? "Trip recording" : "Before you drive")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(began && receipt == nil)
        .onAppear { if !began { recorder.prepare(mode: simulatorMode ? .simulator : .device) } }
        .onDisappear {
            if recorder.isRecording { recorder.endForInterruption(reason: "Recording screen was left. Recording ended; return to save the partial trip.") }
            else { recorder.stopHardware() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                if began && receipt == nil { recorder.endForInterruption() }
                else { recorder.prepare(mode: simulatorMode ? .simulator : .device) }
            }
        }
        .sheet(isPresented: $showDebug) { NavigationStack { MotionDebugView(recorder: recorder) } }
        .alert("Trip not saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("Retry save") { finish() }
            Button("Keep here", role: .cancel) { }
        } message: { Text(saveError ?? "") }
        .navigationDestination(item: $receipt) { trip in TripReceiptView(trip: trip) }
    }

    private var setupContent: some View {
        Group {
            Text("Ready before the road.").font(.largeTitle.bold())
            Surface {
                Label("Only interact while parked", systemImage: "checkmark.shield.fill").font(.headline).foregroundStyle(DS.mint)
                Text("Secure the phone in a flat mount, screen facing up and top edge pointing toward the front of the car. Start before driving. Stop only after parking.")
                Text("Foreground recording only. Leaving the app or locking your phone ends recording; return to save the partial trip. Keep Drive Save open. No driving alerts are sent.").font(.subheadline).foregroundStyle(DS.secondary)
            }
            Surface {
                Toggle("Simulator test mode", isOn: $simulatorMode).accessibilityIdentifier("simulatorMode")
                    .onChange(of: simulatorMode) { _, value in
                        mountingConfirmed = false
                        recorder.prepare(mode: value ? .simulator : .device)
                    }
                if simulatorMode { Text("Generates a synthetic route and events. Saved trips are marked SIMULATED.").font(.caption).foregroundStyle(DS.mint) }
                else {
                    Text(recorder.locationStatus).font(.subheadline).foregroundStyle(DS.secondary)
                    if recorder.authorization == .notDetermined {
                        Button("Enable location") { recorder.requestLocation() }.buttonStyle(.bordered).accessibilityIdentifier("enableLocation")
                    }
                    Text("Denied permission is supported: distance will be unavailable and event detection disabled. You can change permission in iPhone Settings.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            Surface {
                Toggle("I’m parked, securely mounted, and the top edge points forward", isOn: $mountingConfirmed).accessibilityIdentifier("mountConfirmed")
                    .onChange(of: mountingConfirmed) { _, _ in recorder.prepare(mode: simulatorMode ? .simulator : .device) }
                Text(recorder.calibrationStatus).font(.subheadline).foregroundStyle(DS.secondary)
                ProgressView(value: recorder.calibrationProgress).tint(DS.mint)
                Button(recorder.isCalibrated ? "Recalibrate mount" : "Calibrate mounted phone") { recorder.calibrate() }
                    .disabled(!mountingConfirmed).buttonStyle(.bordered).accessibilityIdentifier("calibrate")
                Text(recorder.motionStatus).font(.caption).foregroundStyle(DS.secondary)
                Text("Without calibration, trips still save, but candidate events are unavailable. Calibration uses gravity and your confirmed mounting direction; it cannot infer vehicle axes automatically.").font(.caption).foregroundStyle(DS.secondary)
            }
            Button {
                recorder.start()
                began = recorder.isRecording
            } label: {
                Label(simulatorMode ? "Start simulated trip" : "Start recording", systemImage: "record.circle")
                    .font(.headline).frame(maxWidth: .infinity).padding(12)
            }.buttonStyle(.borderedProminent).disabled(!mountingConfirmed || !recorder.canStart).accessibilityIdentifier("beginRecording")
        }
    }

    private var recordingContent: some View {
        Group {
            if simulatorMode { DemoNotice() }
            Surface {
                Label(recorder.isRecording ? "Recording · foreground only" : "Recording ended", systemImage: recorder.isRecording ? "record.circle" : "pause.circle")
                    .font(.headline).foregroundStyle(DS.mint)
                Text(recorder.elapsedLabel).font(.system(size: 56, weight: .bold, design: .monospaced)).monospacedDigit().accessibilityIdentifier("elapsedTime")
                HStack { Metric(value: recorder.distanceLabel, label: simulatorMode ? "simulated distance" : "GPS distance"); Metric(value: "\(recorder.events.count)", label: "candidate events") }
                Text(recorder.locationStatus).font(.caption).foregroundStyle(DS.secondary)
                Text(recorder.motionStatus).font(.caption).foregroundStyle(DS.secondary)
            }
            Text("Keep your attention on the road. Review details only after parking.").font(.headline).foregroundStyle(DS.secondary)
            if let interruption = recorder.interruption { Text(interruption).font(.subheadline).foregroundStyle(.orange) }
            Button("Stop & save · I’m parked") { finish() }
                .font(.headline).buttonStyle(.borderedProminent).accessibilityIdentifier("stopTrip")
            DisclosureGroup("Parked developer tools") {
                Button("View live sensor measurements") { showDebug = true }.padding(.vertical)
                Text("Open only while stationary. Readings do not measure fuel consumption.").font(.caption).foregroundStyle(DS.secondary)
            }
            if !recorder.events.isEmpty {
                Surface {
                    Eyebrow(text: "Candidate events")
                    ForEach(recorder.events.suffix(5)) { event in
                        HStack { Text(event.kind.label); Spacer(); Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption) }
                    }
                }
            }
        }
    }

    private func finish() {
        if pendingTrip == nil { pendingTrip = recorder.finish() }
        guard let trip = pendingTrip else { return }
        do { try model.save(trip); receipt = trip }
        catch { saveError = "The trip remains in memory. Retry before leaving this screen. \(error.localizedDescription)" }
    }
}

struct MotionDebugView: View {
    @ObservedObject var recorder: TripRecordingService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Screen {
            Text("Parked use only").font(.headline).foregroundStyle(DS.mint)
            Text(recorder.motionStatus).foregroundStyle(DS.secondary)
            if let sample = recorder.latestMotion {
                Surface {
                    Text(sample.timestamp.formatted(date: .omitted, time: .standard)).font(.caption)
                    Text("Uptime: \(sample.uptime, specifier: "%.2f") s")
                    vector("User acceleration · g", sample.userAcceleration)
                    vector("Rotation rate · rad/s", sample.rotationRate)
                    vector("Attitude · roll/pitch/yaw rad", sample.attitude)
                    Text("Forward: \(sample.forwardAcceleration.map { String(format: "%.3f m/s²", $0) } ?? "Uncalibrated")")
                    Text("Lateral: \(sample.lateralAcceleration.map { String(format: "%.3f m/s²", $0) } ?? "Uncalibrated")")
                }.font(.system(.caption, design: .monospaced))
            } else { Text("No motion samples available. Calibrate a mounted real iPhone or start a simulated trip.") }
            Text("Candidate thresholds: braking \(recorder.configuration.brakingThreshold, specifier: "%.1f"), acceleration \(recorder.configuration.accelerationThreshold, specifier: "%.1f"), cornering \(recorder.configuration.corneringThreshold, specifier: "%.1f") m/s². Sustained for \(recorder.configuration.minimumDuration, specifier: "%.1f") s; cooldown \(recorder.configuration.cooldown, specifier: "%.1f") s per event type. Values are provisional.").font(.caption).foregroundStyle(DS.secondary)
        }.navigationTitle("Sensor debug").toolbar { Button("Done") { dismiss() } }
    }
    private func vector(_ title: String, _ value: Vector3) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).foregroundStyle(DS.secondary); Text(String(format: "x %.3f  y %.3f  z %.3f", value.x, value.y, value.z)) }
    }
}
