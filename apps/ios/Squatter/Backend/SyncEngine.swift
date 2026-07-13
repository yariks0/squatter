import Foundation
import SwiftData

/// Best-effort, offline-tolerant sync of the portable training data — never
/// videos, depth, or the heavy pose series. Pushes are fire-and-forget with
/// a dirty marker in UserDefaults (queued payload for sessions, a flag for
/// each profile document); `flush()` retries whatever is still dirty on the
/// next launch/foreground. Pulls run on the home screen (which owns the
/// model context), reconciling remote-only sessions as `RemoteWorkoutSummary`
/// and adopting a newer server profile.
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    private let api: ApiClient
    private let defaults: UserDefaults

    init(api: ApiClient = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
    }

    private enum Key {
        static let pendingSessions = "sync.pendingSessions" // [id: payloadData]
        static let pendingDeletes = "sync.pendingDeletes"   // [id]
        static let bodyDirty = "sync.bodyProfileDirty"
        static let platesDirty = "sync.plateCatalogDirty"
    }

    /// The backend session id for a recording: the video file's UUID base
    /// name (`<uuid>.mov` → `<uuid>`). Pure, so it's callable off the main
    /// actor (e.g. building a `SessionSummary`).
    nonisolated static func sessionID(forVideoFileName name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    // MARK: Push (fire-and-forget, queued)

    func pushSession(_ session: WorkoutSession) {
        let id = Self.sessionID(forVideoFileName: session.videoFileName)
        guard let payload = try? sessionPayload(session) else { return }
        var pending = pendingSessions
        pending[id] = payload
        pendingSessions = pending
        Task { await flush() }
    }

    func deleteSession(videoFileName: String) {
        let id = Self.sessionID(forVideoFileName: videoFileName)
        var pending = pendingSessions
        pending[id] = nil // a delete cancels any unsent push
        pendingSessions = pending
        if !pendingDeletes.contains(id) { pendingDeletes.append(id) }
        Task { await flush() }
    }

    func pushBodyProfile() {
        defaults.set(true, forKey: Key.bodyDirty)
        Task { await flush() }
    }

    func pushPlateCatalog() {
        defaults.set(true, forKey: Key.platesDirty)
        Task { await flush() }
    }

    /// Retries every queued push. Safe to call repeatedly; each success
    /// clears its marker, each failure leaves it for next time.
    func flush() async {
        guard AuthTokenStore.load() != nil else { return }

        for (id, payload) in pendingSessions {
            do {
                try await api.sendRawJSON("PUT", "/v1/sessions/\(id)", json: payload)
                var pending = pendingSessions
                pending[id] = nil
                pendingSessions = pending
            } catch ApiError.unauthenticated {
                return
            } catch {
                // Leave it queued; try again next flush.
            }
        }

        for id in pendingDeletes {
            do {
                try await api.send("DELETE", "/v1/sessions/\(id)")
                pendingDeletes.removeAll { $0 == id }
            } catch ApiError.unauthenticated {
                return
            } catch {}
        }

        if defaults.bool(forKey: Key.bodyDirty), let profile = BodyGeometryProfileStore.load() {
            if let json = try? JSONEncoder().encode(profile),
               (try? await api.sendRawJSON("PUT", "/v1/profile/body", json: json)) != nil {
                defaults.set(false, forKey: Key.bodyDirty)
            }
        }
        if defaults.bool(forKey: Key.platesDirty), let catalog = PlateCatalogStore.load() {
            if let json = try? JSONEncoder().encode(catalog),
               (try? await api.sendRawJSON("PUT", "/v1/profile/plates", json: json)) != nil {
                defaults.set(false, forKey: Key.platesDirty)
            }
        }
    }

    // MARK: Pull (reconcile into the model context)

    func pull(into context: ModelContext) async {
        guard AuthTokenStore.load() != nil else { return }
        await pullSessions(into: context)
        await pullBodyProfile()
        await pullPlateCatalog()
    }

    private func pullSessions(into context: ModelContext) async {
        guard let response = try? await api.fetch(
            SessionsResponse.self, "GET", "/v1/sessions") else { return }

        // Ids already represented locally (a real recording or a prior
        // summary) are skipped — the device recording is the richer copy.
        let localVideoIDs = Set((try? context.fetch(FetchDescriptor<WorkoutSession>()))?
            .map { Self.sessionID(forVideoFileName: $0.videoFileName) } ?? [])
        let existingSummaries = (try? context.fetch(FetchDescriptor<RemoteWorkoutSummary>())) ?? []
        var summaryByID = Dictionary(uniqueKeysWithValues: existingSummaries.map { ($0.id, $0) })

        for dto in response.sessions {
            if localVideoIDs.contains(dto.id) {
                summaryByID[dto.id].map(context.delete) // superseded by a local recording
                continue
            }
            let repsData = (try? ApiClient.makeEncoder().encode(dto.reps)) ?? Data("[]".utf8)
            if let existing = summaryByID[dto.id] {
                existing.date = dto.date
                existing.score = dto.score
                existing.repCount = dto.repCount
                existing.weightKg = dto.weightKg
                existing.repsData = repsData
            } else {
                context.insert(RemoteWorkoutSummary(
                    id: dto.id, date: dto.date, activityRaw: dto.activity,
                    score: dto.score, repCount: dto.repCount, usedLiDAR: dto.usedLidar,
                    weightKg: dto.weightKg, repsData: repsData))
            }
        }
        try? context.save()
    }

    private func pullBodyProfile() async {
        guard let data = try? await api.fetchRawJSON("GET", "/v1/profile/body"),
              let remote = try? JSONDecoder().decode(BodyGeometryProfile.self, from: data)
        else { return }
        // Adopt the server copy only when it's newer than (or replaces a
        // missing) local scan; the payload carries its own scannedAt.
        let local = BodyGeometryProfileStore.load()
        if local == nil || remote.scannedAt > (local?.scannedAt ?? .distantPast) {
            try? BodyGeometryProfileStore.save(remote)
        }
    }

    private func pullPlateCatalog() async {
        // The catalog has no natural timestamp; pull only to seed a device
        // that has none, so a local edit is never clobbered by the server.
        guard PlateCatalogStore.load() == nil,
              let data = try? await api.fetchRawJSON("GET", "/v1/profile/plates"),
              let remote = try? JSONDecoder().decode(PlateCatalog.self, from: data)
        else { return }
        try? PlateCatalogStore.save(remote)
    }

    // MARK: Payload plumbing

    private func sessionPayload(_ session: WorkoutSession) throws -> Data {
        let payload = SessionPushPayload(
            date: session.date,
            activity: session.activityRaw,
            score: session.score,
            repCount: session.repCount,
            usedLidar: session.usedLiDAR,
            weightKg: session.weightKg,
            reps: session.analysis()?.reps ?? [])
        return try ApiClient.makeEncoder().encode(payload)
    }

    private var pendingSessions: [String: Data] {
        get { defaults.dictionary(forKey: Key.pendingSessions) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: Key.pendingSessions) }
    }

    private var pendingDeletes: [String] {
        get { defaults.stringArray(forKey: Key.pendingDeletes) ?? [] }
        set { defaults.set(newValue, forKey: Key.pendingDeletes) }
    }
}

/// The portable slice of a session pushed to the backend — never the video,
/// depth, or pose series. Snake_case + RFC3339 via the ApiClient encoder.
struct SessionPushPayload: Encodable {
    let date: Date
    let activity: String
    let score: Int
    let repCount: Int
    let usedLidar: Bool
    let weightKg: Double?
    let reps: [RepMetrics]
}

private struct SessionsResponse: Decodable {
    let sessions: [SessionDTO]
}

private struct SessionDTO: Decodable {
    let id: String
    let date: Date
    let activity: String
    let score: Int
    let repCount: Int
    let usedLidar: Bool
    let weightKg: Double?
    let reps: [RepMetrics]
}
