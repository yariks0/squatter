import SwiftUI

/// Plate calculator for the review screen: tap out one side of the bar and
/// the total fills the weight field. Detected plate diameters preselect
/// matching catalog plates; unknown diameters open the teach flow — the
/// system measured the size, the user says what it weighs. Built for gyms
/// where every plate is black and only diameter tells them apart.
struct PlatePickerView: View {
    @Binding var weightText: String
    let detected: [PlateDetector.Sighting]
    var scanStatus: PlateScanStatus = .found

    @State private var catalog = PlateCatalogStore.load() ?? PlateCatalog()
    @State private var counts: [PlateSpec: Int] = [:]
    @State private var teachDiameter: TeachTarget?
    @State private var teachWeightText = ""

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
                if detected.isEmpty {
                    Text("Add your gym's plates once — weight and diameter — and future sets total up with a couple of taps. Black no-color plates are fine: diameter is what's matched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // First detection with an empty catalog: one tap seeds the
                    // IWF set so the sighted plates can resolve to kilograms.
                    Button {
                        catalog.plates = PlateCatalog.standardIWFPlates
                        try? PlateCatalogStore.save(catalog)
                        SyncEngine.shared.pushPlateCatalog()
                        applyDetection()
                    } label: {
                        Label(
                            "Plates spotted on the bar — use the standard color set (IWF)?",
                            systemImage: "circle.hexagongrid.fill"
                        )
                        .font(.caption)
                    }
                }
            } else {
                plateChips
            }
            if let statusLine {
                Label(statusLine, systemImage: "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(unknownDetections, id: \.self) { sighting in
                Button {
                    teachDiameter = TeachTarget(sighting: sighting)
                    teachWeightText = ""
                } label: {
                    Label(String(
                        format: "Unknown %@~%.0f cm plate on the bar — teach it?",
                        sighting.color.map { "\($0.rawValue) " } ?? "",
                        sighting.diameterMeters * 100
                    ), systemImage: "questionmark.circle")
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear(perform: applyDetection)
        .onChange(of: detected) { applyDetection() }
        .sheet(item: $teachDiameter) { target in
            teachSheet(target: target)
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
                            HStack(spacing: 4) {
                                if let color = plate.color {
                                    Circle().fill(color.swatch)
                                        .frame(width: 8, height: 8)
                                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                                }
                                Text("\(weightLabel(plate.weightKg))")
                                    .font(.subheadline.bold())
                            }
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

    private func teachSheet(target: TeachTarget) -> some View {
        VStack(spacing: 16) {
            Text(String(
                format: "%@ plate measured at ~%.0f cm across",
                target.sighting.color?.rawValue.capitalized ?? "A",
                target.sighting.diameterMeters * 100
            ))
            .font(.headline)
            Text("Tell it once — every future set recognizes this plate by size\(target.sighting.color != nil ? " and color" : "").")
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
                    let plate = PlateSpec(
                        weightKg: weight,
                        diameterMeters: target.sighting.diameterMeters,
                        color: target.sighting.color
                    )
                    catalog.plates.append(plate)
                    try? PlateCatalogStore.save(catalog)
                    SyncEngine.shared.pushPlateCatalog()
                    counts[plate] = 1
                    // Other sighted classes may resolve now that the catalog
                    // grew — re-apply instead of latching on the first pass.
                    applyDetection()
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

    /// Detected classes with no catalog match — teach candidates.
    private var unknownDetections: [PlateDetector.Sighting] {
        detected.filter {
            catalog.match(diameterMeters: $0.diameterMeters, color: $0.color) == nil
        }
    }

    /// Detection preselects one of each matched class — counts stay the
    /// user's call, plates stack invisibly behind each other. Re-runs
    /// whenever the catalog grows (teach, seed): `counts[plate] == nil`
    /// keeps it idempotent and never overrides an explicit zero.
    private func applyDetection() {
        guard !detected.isEmpty else { return }
        var matchedAny = false
        for sighting in detected {
            if let plate = catalog.match(
                diameterMeters: sighting.diameterMeters, color: sighting.color
            ), counts[plate] == nil {
                counts[plate] = 1
                matchedAny = true
            }
        }
        if matchedAny {
            syncTotal()
        } else if weightText.isEmpty {
            // A bar was sighted even if no plate class resolved — the bar
            // alone still beats an empty field. Never overwrites a typed or
            // prefilled weight.
            weightText = String(format: "%g", catalog.barWeightKg)
        }
    }

    private func syncTotal() {
        weightText = Self.totalText(counts: counts, plateSighted: !detected.isEmpty, catalog: catalog)
    }

    /// Weight-field text for the current taps: the plate total when any are
    /// tapped; the bar's own weight when a bar was sighted on camera but no
    /// plates are tapped (a confirmed bar never weighs nothing); empty
    /// otherwise. Static so the policy is unit-testable.
    static func totalText(counts: [PlateSpec: Int], plateSighted: Bool, catalog: PlateCatalog) -> String {
        if counts.values.contains(where: { $0 > 0 }) {
            return String(format: "%g", catalog.totalKg(perSide: counts))
        }
        return plateSighted ? String(format: "%g", catalog.barWeightKg) : ""
    }

    /// Scan progress caption — silence looked like a missing feature, so the
    /// running and empty-handed states say what happened.
    private var statusLine: String? {
        switch scanStatus {
        case .searching: "Looking for plates on the bar…"
        case .noDepth: "Plate detection needs LiDAR depth — tap plates or type the weight."
        case .none: "No plates recognized — tap plates or type the weight."
        case .found: nil
        }
    }

    private func weightLabel(_ weight: Double) -> String {
        weight.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(weight)) : String(format: "%.2g", weight)
    }
}

/// Where the review-time plate scan stands. Detection's failure mode used to
/// be silence; the picker renders these so "nothing happened" is explained.
enum PlateScanStatus: Equatable {
    /// Scan running (or re-running over the trimmed window).
    case searching
    /// No LiDAR sidecar — metric plate diameters are impossible without it.
    case noDepth
    /// Scan finished without recognizing a plate class.
    case none
    /// Sightings delivered.
    case found
}

/// Sheet target: a measured-but-unknown plate awaiting its weight.
private struct TeachTarget: Identifiable {
    var sighting: PlateDetector.Sighting
    var id: Double { sighting.diameterMeters }
}

extension PlateColor {
    var swatch: Color {
        switch self {
        case .red: .red
        case .blue: .blue
        case .yellow: .yellow
        case .green: .green
        case .white: Color(white: 0.95)
        case .black: .black
        }
    }
}

/// The user's plate inventory: weight + diameter per plate, plus the bar.
struct PlateCatalogEditorView: View {
    @Binding var catalog: PlateCatalog
    @State private var newWeightText = ""
    @State private var newDiameterText = ""
    @State private var newColor: PlateColor?

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
                        if let color = plate.color {
                            Circle().fill(color.swatch)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                        }
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
                        .frame(width: 54)
                    TextField("cm", text: $newDiameterText)
                        .keyboardType(.decimalPad)
                        .frame(width: 54)
                    Picker("", selection: $newColor) {
                        Text("no color").tag(PlateColor?.none)
                        ForEach(PlateColor.allCases) { color in
                            Text(color.rawValue).tag(PlateColor?.some(color))
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button("Add") {
                        guard let weight = Double(newWeightText.replacingOccurrences(of: ",", with: ".")),
                              let diameter = Double(newDiameterText.replacingOccurrences(of: ",", with: ".")),
                              weight > 0, diameter > 5, diameter < 60 else { return }
                        catalog.plates.append(
                            PlateSpec(weightKg: weight, diameterMeters: diameter / 100, color: newColor)
                        )
                        newWeightText = ""
                        newDiameterText = ""
                        newColor = nil
                    }
                    .disabled(newWeightText.isEmpty || newDiameterText.isEmpty)
                }
                if catalog.plates.isEmpty {
                    Button {
                        catalog.plates = PlateCatalog.standardIWFPlates
                    } label: {
                        Label("Add the standard color set (IWF)", systemImage: "circle.hexagongrid.fill")
                    }
                }
            } header: {
                Text("Plates")
            } footer: {
                Text("Plates are recognized by diameter first — measure across the face — with color as the tie-breaker: standard bumpers are all 45 cm and only the color separates 25/20/15/10. All-black plates work as long as their diameters differ by more than ~1 cm.")
            }
        }
        .navigationTitle("Your plates")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            try? PlateCatalogStore.save(catalog)
            SyncEngine.shared.pushPlateCatalog()
        }
    }
}
