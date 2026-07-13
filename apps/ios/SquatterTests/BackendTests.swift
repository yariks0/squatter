import Foundation
import Testing
@testable import Squatter

@MainActor
struct LoginModelTests {
    /// A model wired to record calls and resolve them deterministically.
    private func makeModel(
        requestResult: Result<Void, Error> = .success(()),
        verifyResult: Result<Void, Error> = .success(())
    ) -> LoginModel {
        LoginModel(
            requestCode: { _ in try requestResult.get() },
            verify: { _, _ in try verifyResult.get() },
            cooldownSeconds: 3,
            sleep: { _ in } // no real waiting in tests
        )
    }

    @Test func sendCodeAdvancesToCodeStepAndStartsCooldown() async {
        let model = makeModel()
        model.email = "me@example.com"
        await model.sendCode()
        #expect(model.step == .enterCode(email: "me@example.com"))
        #expect(model.resendCountdown > 0)
        #expect(model.errorMessage == nil)
    }

    @Test func invalidEmailBlocksSend() {
        let model = makeModel()
        model.email = "not-an-email"
        #expect(!model.canSendCode)
    }

    @Test func requestFailureShowsErrorAndStays() async {
        struct Boom: LocalizedError { var errorDescription: String? { "no network" } }
        let model = makeModel(requestResult: .failure(Boom()))
        model.email = "me@example.com"
        await model.sendCode()
        #expect(model.step == .enterEmail)
        #expect(model.errorMessage == "no network")
    }

    @Test func wrongCodeShowsErrorAndClearsCode() async {
        struct Bad: LocalizedError { var errorDescription: String? { "invalid or expired code" } }
        let model = makeModel(verifyResult: .failure(Bad()))
        model.email = "me@example.com"
        await model.sendCode()
        model.code = "123456"
        await model.submitCode()
        #expect(model.errorMessage == "invalid or expired code")
        #expect(model.code.isEmpty)
    }

    @Test func changeEmailResets() async {
        let model = makeModel()
        model.email = "me@example.com"
        await model.sendCode()
        model.changeEmail()
        #expect(model.step == .enterEmail)
        #expect(model.resendCountdown == 0)
    }
}

/// URLProtocol stub that answers requests from a queue of canned responses
/// and records what it saw, so ApiClient can be tested without a server.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let (status, data) = Self.handler?(request) ?? (200, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ApiClientTests {
    private func makeClient(token: String? = "tok") -> ApiClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        var client = ApiClient()
        client.session = URLSession(configuration: config)
        client.token = { token }
        return client
    }

    @Test func sendsBearerHeader() async throws {
        StubURLProtocol.handler = { _ in (204, Data()) }
        try await makeClient().send("POST", "/v1/auth/logout")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
            == "Bearer tok")
    }

    @Test func decodesSnakeCaseResponse() async throws {
        // Encode a full RepMetrics with the API encoder (snake_case), serve
        // it back, and confirm the client decodes it — the round-trip the
        // session sync depends on.
        let rep = RepMetrics(
            repNumber: 2, startTime: 0, endTime: 2, eccentricSeconds: 1,
            concentricSeconds: 1, depthFraction: 0.6, kneeFlexionDegrees: 80,
            hipBelowKneeDegrees: 5, torsoLeanDegrees: 30, kneeValgusRatio: 0.05,
            asymmetryDegrees: 2, meanConcentricVelocity: 0.6)
        let encoded = try ApiClient.makeEncoder().encode(rep)
        StubURLProtocol.handler = { _ in (200, encoded) }
        let decoded = try await makeClient().fetch(RepMetrics.self, "GET", "/v1/x")
        #expect(decoded.repNumber == 2)
        #expect(decoded.meanConcentricVelocity == 0.6)
    }

    @Test func unauthorizedThrowsAndSignals() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        await confirmation { confirmed in
            let observer = NotificationCenter.default.addObserver(
                forName: ApiClient.unauthorizedNotification, object: nil, queue: nil
            ) { _ in confirmed() }
            defer { NotificationCenter.default.removeObserver(observer) }
            do {
                try await makeClient().send("GET", "/v1/me")
                Issue.record("expected unauthenticated")
            } catch ApiError.unauthenticated {
                // expected
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
    }
}

struct SessionSyncPayloadTests {
    /// The push payload round-trips through the API's snake_case encoder into
    /// the shape the backend expects, carrying only the portable slice.
    @Test func payloadEncodesSnakeCaseWithReps() throws {
        let rep = RepMetrics(
            repNumber: 1, startTime: 0, endTime: 2, eccentricSeconds: 1,
            concentricSeconds: 1, depthFraction: 0.6, kneeFlexionDegrees: 80,
            hipBelowKneeDegrees: 5, torsoLeanDegrees: 30, kneeValgusRatio: 0.05,
            asymmetryDegrees: 2, meanConcentricVelocity: 0.6)
        let payload = SessionPushPayload(
            date: Date(timeIntervalSince1970: 1_700_000_000), activity: "squat",
            score: 88, repCount: 1, usedLidar: true, weightKg: 100, reps: [rep])

        let data = try ApiClient.makeEncoder().encode(payload)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["rep_count"] as? Int == 1)
        #expect(json["used_lidar"] as? Bool == true)
        #expect(json["weight_kg"] as? Double == 100)
        let reps = try #require(json["reps"] as? [[String: Any]])
        #expect(reps.first?["mean_concentric_velocity"] as? Double == 0.6)
        // Date is RFC3339, not a raw number.
        #expect(json["date"] is String)
    }

    @Test func sessionIDStripsExtension() {
        #expect(SyncEngine.sessionID(forVideoFileName: "ABC-123.mov") == "ABC-123")
    }
}
