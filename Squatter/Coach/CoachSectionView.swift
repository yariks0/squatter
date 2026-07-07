import SwiftUI

/// "AI coach" section of the set report: runs the LLM assessment on demand
/// and renders the structured report. Degrades gracefully — the deterministic
/// findings above it never depend on this.
struct CoachSectionView: View {
    let analysis: SquatAnalysis
    let videoURL: URL

    private enum Phase {
        case idle, running
        case done(CoachReport)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var showKeyEntry = false
    @State private var keyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI coach")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Set API key…") { promptForKey() }
                    Button("Remove API key", role: .destructive) { CoachKeyStore.delete() }
                } label: {
                    Image(systemName: "key")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .sheet(isPresented: $showKeyEntry) { keyEntrySheet }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Button {
                run()
            } label: {
                Label("Get AI coaching", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("Sends this set's metrics and a few keyframes to Claude. Needs network and your Anthropic API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 10) {
                ProgressView()
                Text("Coach is reviewing the set…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again") { run() }
                    .buttonStyle(.bordered)
            }
        case let .done(report):
            reportView(report)
        }
    }

    private func reportView(_ report: CoachReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Label(report.priorityFix.title, systemImage: "target")
                    .font(.subheadline.bold())
                Text("Cue: \(report.priorityFix.cue)")
                    .font(.subheadline)
                Text(report.priorityFix.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            ForEach(report.findings) { finding in
                FindingRow(finding: finding.asFinding)
            }

            if !report.positives.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep doing")
                        .font(.subheadline.bold())
                    ForEach(report.positives, id: \.self) { positive in
                        Text("• \(positive)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func run() {
        guard CoachKeyStore.load()?.isEmpty == false else {
            promptForKey()
            return
        }
        phase = .running
        Task {
            do {
                phase = .done(try await CoachClient.coach(analysis: analysis, videoURL: videoURL))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func promptForKey() {
        keyDraft = CoachKeyStore.load() ?? ""
        showKeyEntry = true
    }

    private var keyEntrySheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Stored in the device Keychain only. Create a key in the Anthropic Console.")
                }
            }
            .navigationTitle("Anthropic API key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        CoachKeyStore.save(keyDraft)
                        showKeyEntry = false
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showKeyEntry = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
