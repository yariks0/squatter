import Foundation

/// State machine behind `LoginView`, kept UI-free so the flow (send → enter
/// code → verify, resend cooldown, error recovery) is unit-testable. The two
/// network calls are injected closures — tests pass fakes, the view passes
/// `AuthSession`.
@MainActor
@Observable
final class LoginModel {
    enum Step: Equatable {
        case enterEmail
        case enterCode(email: String)
    }

    private(set) var step: Step = .enterEmail
    var email = ""
    var code = ""
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    /// Seconds remaining before "Resend" re-enables; 0 = enabled.
    private(set) var resendCountdown = 0

    private let requestCode: (String) async throws -> Void
    private let verify: (_ email: String, _ code: String) async throws -> Void
    private let cooldownSeconds: Int
    private let sleep: (_ seconds: UInt64) async -> Void

    init(
        requestCode: @escaping (String) async throws -> Void,
        verify: @escaping (String, String) async throws -> Void,
        cooldownSeconds: Int = 60,
        sleep: @escaping (UInt64) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    ) {
        self.requestCode = requestCode
        self.verify = verify
        self.cooldownSeconds = cooldownSeconds
        self.sleep = sleep
    }

    var canSendCode: Bool { !isBusy && Self.looksLikeEmail(email) }
    var canVerify: Bool { !isBusy && code.count == 6 }
    var canResend: Bool { !isBusy && resendCountdown == 0 }

    /// First send: email → code entry.
    func sendCode() async {
        guard canSendCode else { return }
        await runRequest(email: normalizedEmail) { email in
            self.step = .enterCode(email: email)
            self.code = ""
        }
    }

    func resendCode() async {
        guard case let .enterCode(email) = step, canResend else { return }
        await runRequest(email: email, onSuccess: { _ in })
    }

    func submitCode() async {
        guard case let .enterCode(email) = step, canVerify else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await verify(email, code)
            // Success flips AuthSession.state; the view goes away with it.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            code = ""
        }
    }

    /// Back to the email field to fix a typo.
    func changeEmail() {
        step = .enterEmail
        code = ""
        errorMessage = nil
        resendCountdown = 0
    }

    private func runRequest(email: String, onSuccess: @escaping (String) -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await requestCode(email)
            onSuccess(email)
            startCooldown()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startCooldown() {
        resendCountdown = cooldownSeconds
        Task {
            while resendCountdown > 0 {
                await sleep(1)
                resendCountdown -= 1
            }
        }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func looksLikeEmail(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        let domain = value[value.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !value.contains(" ")
    }
}
