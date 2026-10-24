import SwiftUI

struct TripRecordingView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = TripRecordingService()
    @State private var selectedMode: TripRecordingService.Mode = .device
    private var simulatorMode: Bool { selectedMode == .simulator }
    private var walkingMode: Bool { selectedMode == .walking }
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
        .navigationTitle(walkingMode ? "Walking Test" : receipt != nil ? "Trip saved" : began ? "Trip recording" : "Before you drive")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(began && receipt == nil)
        .onAppear { if !began { recorder.prepare(mode: selectedMode) } }
        .onDisappear {
            if recorder.isRecording { recorder.endForInterruption(reason: "Recording screen was left. Recording ended; return to save the partial trip.") }
            else { recorder.stopHardware() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                if began && receipt == nil { recorder.endForInterruption() }
                else { recorder.prepare(mode: selectedMode) }
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
            Picker("Recording mode", selection: $selectedMode) {
                Text("Driving").tag(TripRecordingService.Mode.device)
                Text("Walking Test").tag(TripRecordingService.Mode.walking)
                Text("Demo Drive").tag(TripRecordingService.Mode.simulator)
            }.pickerStyle(.segmented).accessibilityIdentifier("recordingMode")
                .onChange(of: selectedMode) { _, _ in
                    mountingConfirmed = false
                    recorder.prepare(mode: selectedMode)
                }
            Text(walkingMode ? "Walking GPS Test" : "Ready before the road.").font(.largeTitle.bold())
            Surface {
                Label(walkingMode ? "Core Location · Walking Test" : "Only interact while parked", systemImage: walkingMode ? "figure.walk" : "checkmark.shield.fill").font(.headline).foregroundStyle(DS.mint)
                Text(walkingMode ? "Walk outdoors with your iPhone in any comfortable position. Only GPS distance and elapsed time are recorded. Phone angle can change; no calibration is needed." : "Secure the phone in a flat mount, screen facing up and top edge pointing toward the front of the car. Start before driving. Stop only after parking.")
                Text(walkingMode ? "Driving-event detection and fuel estimates are off. Walking Tests do not contribute to driving history totals or league rankings. Stop walking before reviewing the screen." : "Foreground recording only. Leaving the app or locking your phone ends recording; return to save the partial trip. Keep Drive Save open. No driving alerts are sent.").font(.subheadline).foregroundStyle(DS.secondary)
                if walkingMode { Text("Keep this screen open. Locking the phone, switching tabs or leaving the app ends capture; return to save.").font(.caption).foregroundStyle(DS.secondary) }
            }
            Surface {
                if simulatorMode { Text("Generates a synthetic route and events. Saved trips are marked SIMULATED.").font(.caption).foregroundStyle(DS.mint) }
                else {
                    Text(recorder.locationStatus).font(.subheadline).foregroundStyle(DS.secondary)
                    if recorder.authorization == .notDetermined {
                        Button("Enable location") { recorder.requestLocation() }.buttonStyle(.bordered).accessibilityIdentifier("enableLocation")
                    }
                    Text("If permission is denied, elapsed time can still be saved but distance is unavailable. Enable Precise Location in iPhone Settings for better GPS readings.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            if !walkingMode {
                Surface {
                    Toggle("I’m parked, securely mounted, and the top edge points forward", isOn: $mountingConfirmed).accessibilityIdentifier("mountConfirmed")
                        .onChange(of: mountingConfirmed) { _, _ in recorder.prepare(mode: selectedMode) }
                    Text(recorder.calibrationStatus).font(.subheadline).foregroundStyle(DS.secondary)
                    ProgressView(value: recorder.calibrationProgress).tint(DS.mint)
                    Button(recorder.isCalibrated ? "Recalibrate mount" : "Calibrate mounted phone") { recorder.calibrate() }
                        .disabled(!mountingConfirmed).buttonStyle(.bordered).accessibilityIdentifier("calibrate")
                    Text(recorder.motionStatus).font(.caption).foregroundStyle(DS.secondary)
                    Text("Without calibration, GPS trips still save, but driving events are unavailable. Calibration uses gravity and your confirmed mounting direction.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            Button {
                recorder.start()
                began = recorder.isRecording
            } label: {
                Label(walkingMode ? "Start Walking Test" : simulatorMode ? "Start simulated trip" : "Start recording", systemImage: "record.circle")
                    .font(.headline).frame(maxWidth: .infinity).padding(12)
            }.buttonStyle(.borderedProminent).disabled((!walkingMode && !mountingConfirmed) || !recorder.canStart).accessibilityIdentifier("beginRecording")
        }
    }

    private var recordingContent: some View {
        Group {
            if simulatorMode { DemoNotice() }
            if walkingMode { Label("Walking Test · Core Location", systemImage: "figure.walk").foregroundStyle(DS.mint).font(.headline) }
            Surface {
                Label(recorder.isRecording ? "Recording · foreground only" : "Recording ended", systemImage: recorder.isRecording ? "record.circle" : "pause.circle")
                    .font(.headline).foregroundStyle(DS.mint)
                Text(recorder.elapsedLabel).font(.system(size: 56, weight: .bold, design: .monospaced)).monospacedDigit().accessibilityIdentifier("elapsedTime")
                HStack { Metric(value: recorder.distanceLabel, label: simulatorMode ? "simulated distance" : "GPS distance"); Metric(value: recorder.eventCountLabel, label: "driving events") }
                Text(recorder.locationStatus).font(.caption).foregroundStyle(DS.secondary)
                Text("GPS accuracy: \(recorder.accuracyLabel)").font(.caption).foregroundStyle(DS.secondary).accessibilityIdentifier("gpsAccuracy")
                Text(recorder.calibrationLabel).font(.caption).foregroundStyle(DS.secondary)
                Text(recorder.detectionStatus).font(.caption).foregroundStyle(DS.secondary).accessibilityIdentifier("detectionStatus")
                if recorder.measurementsIncomplete {
                    Label("Measurements incomplete · see GPS and detection status above", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Text(walkingMode ? "Stop walking before reviewing or saving your Walking Test." : "Keep your attention on the road. Review details only after parking.").font(.headline).foregroundStyle(DS.secondary)
            if let interruption = recorder.interruption { Text(interruption).font(.subheadline).foregroundStyle(.orange) }
            Button(walkingMode ? "Stop & save Walking Test" : "Stop & save · I’m parked") { finish() }
                .font(.headline).buttonStyle(.borderedProminent).accessibilityIdentifier("stopTrip")
            if !walkingMode {
            DisclosureGroup("Parked developer tools") {
                Button("View live sensor measurements") { showDebug = true }.padding(.vertical)
                Text("Open only while stationary. Readings do not measure fuel consumption.").font(.caption).foregroundStyle(DS.secondary)
            }
            }
            if !walkingMode && !recorder.events.isEmpty {
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
