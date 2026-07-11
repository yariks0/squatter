import SwiftUI

/// Plate calculator for the review screen: tap out one side of the bar and
/// the total fills the weight field. Detected plate diameters preselect
/// matching catalog plates; unknown diameters open the teach flow — the
/// system measured the size, the user says what it weighs. Built for gyms
/// where every plate is black and only diameter tells them apart.
struct PlatePickerView: View {
    @Binding var weightText: String
    let detectedDiameters: [Double]

    @State private var catalog = PlateCatalogStore.load() ?? PlateCatalog()
    @State private var counts: [PlateSpec: Int] = [:]
    @State private var teachDiameter: TeachTarget?
    @State private var teachWeightText = ""
    @State private var appliedDetection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Plates per side", systemImage: "circle.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("bar \(weightLabel(catalog.barWeightKg)) kg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NavigationLink("Edit plates") {
                    PlateCatalogEditorView(catalog: $catalog)
                }
                .font(.caption)
            }
            if catalog.plates.isEmpty {
                Text("Add your gym's plates once — weight and diameter — and future sets total up with a couple of taps. Black no-color plates are fine: diameter is what's matched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                plateChips
            }
            ForEach(unknownDetections, id: \.self) { diameter in
                Button {
                    teachDiameter = TeachTarget(diameterMeters: diameter)
                    teachWeightText = ""
                } label: {
                    Label(String(
                        format: "Unknown ~%.0f cm plate on the bar — teach it?", diameter * 100
                    ), systemImage: "questionmark.circle")
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear(perform: applyDetection)
        .onChange(of: detectedDiameters) { applyDetection() }
        .sheet(item: $teachDiameter) { target in
            teachSheet(diameter: target.diameterMeters)
                .presentationDetents([.height(230)])
        }
    }

    private var plateChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sortedPlates) { plate in
                    let count = counts[plate] ?? 0
                    Button {
                        counts[plate] = count + 1
                        syncTotal()
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(weightLabel(plate.weightKg))")
                                .font(.subheadline.bold())
                            Text(count > 0
                                 ? "×\(count)"
                                 : String(format: "%.0f cm", plate.diameterMeters * 100))
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            count > 0 ? Color.accentColor.opacity(0.25) : Color.clear,
                            in: Capsule()
                        )
                        .overlay(Capsule().strokeBorder(
                            count > 0 ? Color.accentColor : Color.secondary.opacity(0.4)
                        ))
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture().onEnded { _ in
                        counts[plate] = 0
                        syncTotal()
                    })
                }
                if counts.values.contains(where: { $0 > 0 }) {
                    Button("Clear") {
                        counts = [:]
                        syncTotal()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func teachSheet(diameter: Double) -> some View {
        VStack(spacing: 16) {
            Text(String(format: "Plate measured at ~%.0f cm across", diameter * 100))
                .font(.headline)
            Text("Tell it once — every future set recognizes this plate by size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Weight", text: $teachWeightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text("kg")
            }
            Button("Save plate") {
                if let weight = Double(teachWeightText.replacingOccurrences(of: ",", with: ".")),
                   weight > 0 {
                    let plate = PlateSpec(weightKg: weight, diameterMeters: diameter)
                    catalog.plates.append(plate)
                    try? PlateCatalogStore.save(catalog)
                    counts[plate] = 1
                    syncTotal()
                }
                teachDiameter = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var sortedPlates: [PlateSpec] {
        catalog.plates.sorted { $0.weightKg > $1.weightKg }
    }

    /// Detected diameters with no catalog match — teach candidates.
    private var unknownDetections: [Double] {
        detectedDiameters.filter { catalog.match(diameterMeters: $0) == nil }
    }

    /// Detection preselects one of each matched class exactly once — counts
    /// stay the user's call, plates stack invisibly behind each other.
    private func applyDetection() {
        guard !appliedDetection, !detectedDiameters.isEmpty else { return }
        appliedDetection = true
        var matchedAny = false
        for diameter in detectedDiameters {
            if let plate = catalog.match(diameterMeters: diameter), counts[plate] == nil {
                counts[plate] = 1
                matchedAny = true
            }
        }
        if matchedAny { syncTotal() }
    }

    private func syncTotal() {
        let total = catalog.totalKg(perSide: counts)
        weightText = total > catalog.barWeightKg || counts.values.contains(where: { $0 > 0 })
            ? String(format: "%g", total) : ""
    }

    private func weightLabel(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(weight)) : String(format: "%.2g", weight)
    }
}

/// Sheet target: a measured-but-unknown plate awaiting its weight.
private struct TeachTarget: Identifiable {
    var diameterMeters: Double
    var id: Double { diameterMeters }
}

/// The user's plate inventory: weight + diameter per plate, plus the bar.
struct PlateCatalogEditorView: View {
    @Binding var catalog: PlateCatalog
    @State private var newWeightText = ""
    @State private var newDiameterText = ""

    var body: some View {
        List {
            Section("Bar") {
                HStack {
                    Text("Bar weight")
                    Spacer()
                    TextField("20", value: $catalog.barWeightKg, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("kg").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(catalog.plates.sorted { $0.weightKg > $1.weightKg }) { plate in
                    HStack {
                        Text(String(format: "%g kg", plate.weightKg))
                        Spacer()
                        Text(String(format: "%.1f cm", plate.diameterMeters * 100))
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let sorted = catalog.plates.sorted { $0.weightKg > $1.weightKg }
                    for offset in offsets {
                        catalog.plates.removeAll { $0.id == sorted[offset].id }
                    }
                }
                HStack {
                    TextField("kg", text: $newWeightText)
                        .keyboardType(.decimalPad)
                        .frame(width: 60)
                    TextField("diameter cm", text: $newDiameterText)
                        .keyboardType(.decimalPad)
                    Button("Add") {
                        guard let weight = Double(newWeightText.replacingOccurrences(of: ",", with: ".")),
                              let diameter = Double(newDiameterText.replacingOccurrences(of: ",", with: ".")),
                              weight > 0, diameter > 5, diameter < 60 else { return }
                        catalog.plates.append(
                            PlateSpec(weightKg: weight, diameterMeters: diameter / 100)
                        )
                        newWeightText = ""
                        newDiameterText = ""
                    }
                    .disabled(newWeightText.isEmpty || newDiameterText.isEmpty)
                }
            } header: {
                Text("Plates")
            } footer: {
                Text("Diameter is how a plate is recognized on the bar — measure across the face. Two plates within ~1 cm of each other can't be told apart automatically.")
            }
        }
        .navigationTitle("Your plates")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? PlateCatalogStore.save(catalog) }
    }
}
