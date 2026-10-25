import SwiftUI

struct MyVehicleView: View {
    var developerTools = false
    @EnvironmentObject private var backend: BackendViewModel
    @State private var showCalculation = false
    @State private var calculation: (id: UUID, vehicle: VehicleRow, service: TestCalculationService)?
    @State private var calculationError: String?
    var body: some View {
        Screen {
            if let row = backend.vehicle {
                if let vehicle = try? CatalogVehicle(row: row) { VehicleSummary(vehicle: vehicle) }
                else {
                    DisplayType(row.vehicleTitle.isEmpty ? "Imported vehicle" : row.vehicleTitle, size: 40)
                    Text("Vehicle details unavailable").foregroundStyle(DS.secondary)
                }
            } else if backend.isBusy { ProgressView("Loading vehicle…") }
            else { Text("No vehicle selected").font(DS.section) }
            NavigationLink(backend.vehicle == nil ? "Choose vehicle" : "Change vehicle") { VehiclePickerView() }
                .buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("chooseVehicle")
            if developerTools {
                Button("Test Calculation") {
                    do {
                        guard let row = backend.vehicle else { return }
                        calculation = (UUID(), row, try backend.calculationService()); calculationError = nil; showCalculation = true
                    } catch { calculationError = error.localizedDescription }
                }.buttonStyle(.bordered).accessibilityIdentifier("testCalculation")
                    .disabled(!backend.canTestCalculation || backend.isBusy)
                if backend.isRemote, backend.vehicle != nil, !backend.canTestCalculation {
                    Text("Save or upload this vehicle before testing.").font(.caption).foregroundStyle(DS.secondary)
                }
                if let calculationError { Text(calculationError).foregroundStyle(.orange) }
                if !backend.isRemote { Text("Offline demo · sample catalog. Calculation tests require online mode.").font(.caption).foregroundStyle(DS.secondary) }
            }
            if backend.errorMessage != nil { Text("Vehicle details couldn’t be refreshed. Try again.").font(.subheadline).foregroundStyle(.orange) }
        }
        .navigationTitle("My Vehicle").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showCalculation) {
            if let calculation { TestCalculationView(vehicle: calculation.vehicle, service: calculation.service).id(calculation.id) }
        }
        .task { await backend.refreshMyVehicle() }
        .refreshable { await backend.refreshMyVehicle() }
    }
}

struct VehiclePickerView: View {
    @EnvironmentObject private var backend: BackendViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var picker = VehiclePickerViewModel()
    @State private var selection: VehicleSelectionStep?
    @State private var saving = false
    @State private var saveError: String?
    var body: some View {
        Screen {
            if !backend.isRemote { Eyebrow(text: "Offline demo · sample catalog") }
            VStack(spacing: 0) {
                selectionButton("Brand", value: picker.make, step: .brand)
                selectionButton("Model", value: picker.model, step: .model).disabled(picker.make == nil)
                selectionButton("Year", value: picker.year.map(String.init), step: .year).disabled(picker.model == nil)
            }
            if picker.isLoading { ProgressView("Loading details…") }
            if picker.error != nil {
                Text("Vehicle details are unavailable. Please try again.").foregroundStyle(.orange)
                Button("Retry") { Task { await loadDetails() } }
            }
            if let vehicle = picker.vehicle {
                VehicleSummary(vehicle: vehicle)
                Button(saving ? "Saving…" : "Save") {
                    saving = true; saveError = nil
                    Task {
                        if await backend.saveCatalogVehicle(vehicle) { dismiss() }
                        else { saveError = backend.errorMessage ?? "Vehicle could not be saved. Please retry." }
                        saving = false
                    }
                }.buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("saveCatalogVehicle")
                    .disabled(backend.isBusy)
            }
            if saveError != nil { Text("Your vehicle couldn’t be saved. Please try again.").foregroundStyle(.orange) }
        }
        .disabled(saving)
        .navigationTitle("Choose vehicle").navigationBarTitleDisplayMode(.inline)
        .task(id: picker.choice) { await loadDetails() }
        .sheet(item: $selection) { step in
            VehicleSelectionView(step: step, make: picker.make, model: picker.model) { value in
                saveError = nil
                switch step {
                case .brand: picker.selectMake(value)
                case .model: picker.selectModel(value)
                case .year: if let year = Int(value) { picker.selectYear(year) }
                }
            }
        }
    }
    private func loadDetails() async { await picker.loadDetails { try await backend.vehicleDetails($0) } }
    private func selectionButton(_ label: String, value: String?, step: VehicleSelectionStep) -> some View {
        Button { selection = step } label: {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: label)
                HStack(alignment: .firstTextBaseline) {
                    Text(value ?? "Select").font(.title3.weight(.semibold)).foregroundStyle(value == nil ? DS.secondary : DS.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right").foregroundStyle(DS.acid)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                .contentShape(Rectangle()).overlay(alignment: .bottom) { MeasurementRule() }
        }.buttonStyle(.plain).accessibilityIdentifier("selectVehicle\(label)")
    }
}

enum VehicleSelectionStep: String, Identifiable {
    case brand = "Brand", model = "Model", year = "Year"
    var id: String { rawValue }
}

private struct VehicleSelectionView: View {
    let step: VehicleSelectionStep
    let make: String?
    let model: String?
    let select: (String) -> Void
    @EnvironmentObject private var backend: BackendViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var options: [String] = []
    @State private var loading = true
    @State private var error: String?
    private var filtered: [String] { query.isEmpty ? options : options.filter { $0.localizedStandardContains(query) } }
    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { value in
                Button { select(value); dismiss() } label: {
                    Text(value).foregroundStyle(DS.ink).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.listRowBackground(DS.background).accessibilityIdentifier("vehicleOption-\(value)")
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(DS.background)
            .searchable(text: $query, prompt: "Search \(step.rawValue.lowercased())")
            .overlay {
                if loading { ProgressView("Loading…") }
                else if error != nil {
                    VStack(spacing: 16) { Text("Vehicle details are unavailable. Please try again.").foregroundStyle(.orange); Button("Retry") { Task { await load() } } }.padding(24)
                } else if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No \(step.rawValue.lowercased())s available" : "No results", systemImage: "magnifyingglass", description: Text(query.isEmpty ? "Try again later or choose another vehicle." : "Try a different search."))
                }
            }
            .navigationTitle(step.rawValue).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }.tint(DS.acid).preferredColorScheme(.dark)
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let values: [String]
            switch step {
            case .brand: values = try await backend.vehicleMakes()
            case .model: values = try await backend.vehicleModels(make: make ?? "")
            case .year: values = try await backend.vehicleYears(make: make ?? "", model: model ?? "").map(String.init)
            }
            try Task.checkCancellation()
            var seen = Set<String>()
            options = values.filter { seen.insert($0).inserted }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct VehicleSummary: View {
    let vehicle: CatalogVehicle
    private var details: CatalogVehicle.Details { vehicle.details }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DisplayType(vehicle.title, size: 40).accessibilityIdentifier("selectedVehicleTitle")
            Text(vehicle.supportsFuelModel ? "EPA fuel economy estimates" : "Fuel estimates unavailable for this vehicle")
                .font(.subheadline).foregroundStyle(vehicle.supportsFuelModel ? DS.secondary : .orange)
                .accessibilityIdentifier("vehicleEligibility")
            if details.mpg.combined != nil || details.mpg.city != nil || details.mpg.highway != nil {
                Surface {
                    if let combined = details.mpg.combined { ReceiptLedgerLine(label: "Combined MPG", value: combined.formatted()) }
                    if let city = details.mpg.city { ReceiptLedgerLine(label: "City", value: city.formatted()) }
                    if let highway = details.mpg.highway { ReceiptLedgerLine(label: "Highway", value: highway.formatted()) }
                    Text(details.mpg.is_estimate ? "EPA-derived estimates · may differ from the window sticker" : "EPA catalog MPG").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            Surface {
                ReceiptLedgerLine(label: "Fuel", value: details.specs.fuel_type.capitalized)
                if details.specs.fuel_type != "electricity", let liters = details.specs.engine_displacement_l {
                    ReceiptLedgerLine(label: "Engine", value: "\(liters.formatted()) L")
                }
                if let cylinders = details.specs.cylinders { ReceiptLedgerLine(label: "Cylinders", value: String(cylinders)) }
                if let power = details.specs.rated_horsepower { ReceiptLedgerLine(label: "Power", value: "\(power.formatted()) hp") }
                if let transmission = details.specs.transmission { ReceiptLedgerLine(label: "Transmission", value: transmission) }
                if let drive = details.specs.drive { ReceiptLedgerLine(label: "Drive", value: drive) }

            }

        }
    }
}
