import Foundation
import SwiftUI

/// App-wide auth state and the entry point for the login flow. The root view
/// switches on `state`; requests that 401 flip it back to `.loggedOut`.
@MainActor
@Observable
final class AuthSession {
    enum State: Equatable {
        case checking
        case loggedOut
        case loggedIn(email: String)
        /// The user chose to use the app without a backend session. Sync and
        /// coaching quietly no-op (they require a bearer token); everything
        /// local — recording, offline analysis, the plate/body profile —
        /// works unchanged.
        case offline
    }

    private(set) var state: State
    private let api: ApiClient

    init(api: ApiClient = .shared) {
        self.api = api
        // Optimistic: a stored token means "logged in" without a round-trip;
        // a background /me confirms and logs out if it was revoked. With no
        // token, resume offline mode if the user last chose it, otherwise
        // show the login gate.
        if AuthTokenStore.load() != nil {
            state = .checking
        } else {
            state = Self.offlinePreferred ? .offline : .loggedOut
        }
    }

    /// Call once at launch. Confirms a stored token and wires the global
    /// 401 → logout signal.
    func start() {
        NotificationCenter.default.addObserver(
            forName: ApiClient.unauthorizedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceLoggedOut() }
        }
        guard case .checking = state else { return }
        Task { await confirmSession() }
    }

    private func confirmSession() async {
        do {
            let me = try await api.fetch(MeResponse.self, "GET", "/v1/me")
            state = .loggedIn(email: me.email)
        } catch ApiError.unauthenticated {
            forceLoggedOut()
        } catch {
            // Network hiccup, not an auth failure: trust the stored token and
            // let later requests re-validate rather than bouncing to login.
            if let email = lastKnownEmail {
                state = .loggedIn(email: email)
            } else {
                state = .loggedOut
            }
        }
    }

    // MARK: Login flow (called by LoginModel)

    func requestCode(email: String) async throws {
        try await api.send(
            "POST", "/v1/auth/request-code",
            body: ["email": email], authorized: false)
    }

    func verify(email: String, code: String) async throws {
        let response = try await api.fetch(
            VerifyResponse.self, "POST", "/v1/auth/verify",
            body: ["email": email, "code": code], authorized: false)
        AuthTokenStore.save(response.token)
        lastKnownEmail = response.user.email
        Self.offlinePreferred = false
        state = .loggedIn(email: response.user.email)
    }

    /// Enter the app without signing in. Remembered so relaunches stay offline
    /// until the user signs in or explicitly returns to the login screen.
    func enterOfflineMode() {
        Self.offlinePreferred = true
        state = .offline
    }

    /// Leave offline mode to sign in (from the account menu).
    func showLogin() {
        Self.offlinePreferred = false
        state = .loggedOut
    }

    func logout() {
        let hadToken = AuthTokenStore.load() != nil
        AuthTokenStore.delete()
        lastKnownEmail = nil
        Self.offlinePreferred = false
        state = .loggedOut
        if hadToken {
            Task { try? await api.send("POST", "/v1/auth/logout") }
        }
    }

    private func forceLoggedOut() {
        AuthTokenStore.delete()
        state = .loggedOut
    }

    // Remembered so a transient /me failure doesn't lose the email label.
    private var lastKnownEmail: String? {
        get { UserDefaults.standard.string(forKey: "auth.lastEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "auth.lastEmail") }
    }

    // Sticky choice to run without a session, so relaunch skips the gate.
    private static var offlinePreferred: Bool {
        get { UserDefaults.standard.bool(forKey: "auth.offlineMode") }
        set { UserDefaults.standard.set(newValue, forKey: "auth.offlineMode") }
    }
}

private struct MeResponse: Decodable { let id: String; let email: String }
private struct VerifyResponse: Decodable {
    struct User: Decodable { let id: String; let email: String }
    let token: String
    let user: User
}
