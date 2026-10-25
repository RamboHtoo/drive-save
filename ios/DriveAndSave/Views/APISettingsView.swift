import SwiftUI
import UniformTypeIdentifiers

struct APISettingsView: View {
    @EnvironmentObject private var backend: BackendViewModel
    @EnvironmentObject private var model: AppViewModel
    @State private var remote = false
    @State private var baseURL = "https://drivesave.nuhylabs.com"
    @State private var vehicleJSON = ""
    @State private var confirmedVehicle = false
    @State private var importing = false
    var body: some View {
        Screen {
            NavigationLink("Test Calculation") { MyVehicleView(developerTools: true) }.accessibilityIdentifier("developerCalculation")
            NavigationLink("Recording tests") { TripRecordingView() }
            NavigationLink("History & receipt diagnostics") {
                Screen {
                    ForEach(model.trips) { trip in
                        NavigationLink(trip.displayTitle) { TripReceiptAdvancedView(trip: trip) }
                    }
                }.navigationTitle("Trip diagnostics")
            }
            Surface {
                Eyebrow(text: "API connection")
                Toggle("Use remote backend", isOn: $remote)
                TextField("API base URL", text: $baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Apply connection") { Task { await backend.connect(remote: remote, baseURL: baseURL) } }.buttonStyle(.bordered)
                Text(backend.isRemote ? "Remote · requests go to the selected server" : "Offline mock · no server requests").font(.caption).foregroundStyle(DS.mint)
            }
            AccountAdvancedSettings()
            Surface {
                Eyebrow(text: "Complete EPA vehicle row")
                Text("Import your selected EPA JSON row without changing its field names. The supplied 2026 Honda Civic row is a backend example, not an assumed vehicle profile.").font(.subheadline).foregroundStyle(DS.secondary)
                HStack {
                    Button("Load EPA example") {
                        do { let row = try BackendFixtures.load("sample-vehicle", as: VehicleRow.self); vehicleJSON = String(data: try APIJSON.encoder().encode(row), encoding: .utf8) ?? ""; confirmedVehicle = false }
                        catch { backend.errorMessage = error.localizedDescription }
                    }.accessibilityIdentifier("loadVehicleExample")
                    Button("Import JSON") { importing = true }
                }.buttonStyle(.bordered)
                TextEditor(text: $vehicleJSON).font(.system(.caption, design: .monospaced)).frame(minHeight: 180).scrollContentBackground(.hidden).accessibilityIdentifier("vehicleJSON")
                Toggle("This EPA row matches my actual vehicle", isOn: $confirmedVehicle)
                Button("Save vehicle selection") { backend.selectVehicle(json: vehicleJSON, confirmed: confirmedVehicle) }.buttonStyle(.bordered).accessibilityIdentifier("saveVehicle")
                if let row = backend.vehicle {
                    Text("Selected: \(row.vehicleTitle)").font(.headline)
                    Text("\(row.count) original fields · \(backend.vehicleConfirmed ? "confirmed vehicle" : "example / unconfirmed")").font(.caption).foregroundStyle(DS.secondary)
                }
                HStack {
                    Button("Upload vehicle") { Task { await backend.updateVehicle() } }
                    Button("Fetch server vehicle") { Task { await backend.fetchVehicle(); loadSelectedVehicle() } }
                }.buttonStyle(.bordered)
            }
            BackendStatusView()
        }
        .navigationTitle("Developer tools").navigationBarTitleDisplayMode(.inline)
        .disabled(backend.isBusy)
        .onAppear { remote = backend.isRemote; baseURL = backend.connectionURL; loadSelectedVehicle() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count < 20_000 else { throw BackendError.invalidInput("Vehicle JSON must be under 20 KB.") }
                _ = try APIJSON.decoder().decode(VehicleRow.self, from: data)
                vehicleJSON = String(decoding: data, as: UTF8.self); confirmedVehicle = false
            } catch { backend.errorMessage = error.localizedDescription }
        }
    }
    private func loadSelectedVehicle() {
        if let row = backend.vehicle { vehicleJSON = String(data: (try? APIJSON.encoder().encode(row)) ?? Data(), encoding: .utf8) ?? ""; confirmedVehicle = backend.vehicleConfirmed }
    }
}

struct BackendStatusView: View {
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        if backend.isBusy { ProgressView("Connecting…") }
        if let notice = backend.notice { Text(notice).font(.subheadline).foregroundStyle(DS.mint).textSelection(.enabled) }
        if let error = backend.errorMessage { Text(error).font(.subheadline).foregroundStyle(.orange).textSelection(.enabled) }
    }
}

/// Normal screens retain actionable failures without exposing server diagnostics.
struct ConsumerBackendStatusView: View {
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        if backend.isBusy { ProgressView("Updating…") }
        if backend.errorMessage != nil { Text(backend.consumerErrorMessage ?? "We couldn’t complete that request. Check your connection and try again.").font(.subheadline).foregroundStyle(.orange) }
    }
}

struct TripUploadSection: View {
    let trip: Trip
    @EnvironmentObject private var backend: BackendViewModel
    var body: some View {
        Surface {
            if backend.unsupportedReason(for: trip) != nil {
                Text(backend.insufficientReason(for: trip) != nil ? "Insufficient recording data" : "Use the account and vehicle selected when this recording began. Older recordings remain available for inspection.").font(.subheadline).foregroundStyle(DS.secondary)
            } else {
                Button("Get estimate") { Task { await backend.upload(trip: trip) } }.buttonStyle(IgnitionButtonStyle()).disabled(backend.isBusy)
            }
            if backend.insufficientReason(for: trip) == nil { ConsumerBackendStatusView() }
        }
    }
}
