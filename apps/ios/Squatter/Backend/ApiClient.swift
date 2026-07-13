import Foundation

enum ApiError: LocalizedError {
    /// The server rejected our token — the caller should drop to the login
    /// screen. Posted app-wide so any request can trigger logout.
    case unauthenticated
    case http(Int, String?)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .unauthenticated: "Your session expired. Please sign in again."
        case let .http(status, message): message ?? "Request failed (HTTP \(status))."
        case let .transport(error): error.localizedDescription
        case .decoding: "The server sent an unexpected response."
        }
    }
}

/// Thin typed client for the Go backend. Owns the JSON conventions the
/// backend speaks (snake_case + RFC3339 dates with fractional seconds) —
/// deliberately separate from the default encoders used for on-device
/// persistence, which must not change. Injects the bearer token and signals
/// a global logout on 401.
struct ApiClient: Sendable {
    static let shared = ApiClient()

    /// Posted when any request sees a 401, so `AuthSession` can log out.
    static let unauthorizedNotification = Notification.Name("SquatterApiUnauthorized")

    var baseURL = BackendConfig.baseURL
    var session: URLSession = .shared
    /// Overridable so tests can inject a token without the Keychain.
    var token: @Sendable () -> String? = { AuthTokenStore.load() }

    // Go's time.Time marshals RFC3339 with fractional seconds; the stock
    // .iso8601 strategy rejects the fraction, so parse/format explicitly.
    // ISO8601DateFormatter and JSON coders are immutable after setup here and
    // only ever read, so sharing them across tasks is safe.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = dateFormatter.date(from: raw) ?? plainDateFormatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        return decoder
    }

    private static let encoder = makeEncoder()
    private static let decoder = makeDecoder()

    // MARK: Requests

    /// Sends a request expecting no body back (204/200). `authorized: false`
    /// for the login endpoints.
    func send(
        _ method: String, _ path: String,
        body: (any Encodable)? = nil, authorized: Bool = true
    ) async throws {
        _ = try await perform(method, path, body: body, authorized: authorized)
    }

    /// Sends pre-encoded JSON bytes as the body — for the profile documents,
    /// which are stored opaquely by the server in the app's own local
    /// encoding (camelCase, not the API's snake_case). Returns true on 2xx,
    /// throws on auth/transport failure.
    func sendRawJSON(_ method: String, _ path: String, json: Data) async throws {
        _ = try await perform(method, path, rawBody: json, authorized: true)
    }

    /// Fetches a raw JSON body (the opaque profile documents); nil on 404.
    func fetchRawJSON(_ method: String, _ path: String) async throws -> Data? {
        do {
            return try await perform(method, path, authorized: true)
        } catch let ApiError.http(status, _) where status == 404 {
            return nil
        }
    }

    /// Sends a request and decodes the JSON response into `T`.
    func fetch<T: Decodable>(
        _ type: T.Type = T.self, _ method: String, _ path: String,
        body: (any Encodable)? = nil, authorized: Bool = true
    ) async throws -> T {
        let data = try await perform(method, path, body: body, authorized: authorized)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ApiError.decoding(error)
        }
    }

    @discardableResult
    private func perform(
        _ method: String, _ path: String,
        body: (any Encodable)? = nil, rawBody: Data? = nil, authorized: Bool
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let rawBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        } else if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(AnyEncodable(body))
        }
        if authorized {
            guard let token = token() else { throw ApiError.unauthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ApiError.transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            NotificationCenter.default.post(name: Self.unauthorizedNotification, object: nil)
            throw ApiError.unauthenticated
        }
        guard (200 ..< 300).contains(status) else {
            throw ApiError.http(status, Self.errorMessage(from: data))
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String? {
        struct Body: Decodable { struct E: Decodable { let message: String }; let error: E }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error.message
    }
}

/// Type-erases an `Encodable` so a heterogeneous body can flow through one
/// generic encode call.
private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) { encode = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
