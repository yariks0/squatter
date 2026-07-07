import Foundation

enum CoachError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refused(String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "Add your Anthropic API key to get AI coaching."
        case let .http(status, message):
            "The coaching request failed (HTTP \(status)): \(message)"
        case let .refused(explanation):
            explanation ?? "The model declined to assess this set."
        case .badResponse:
            "Could not read the coaching response."
        }
    }
}

/// Sends the set to the Anthropic Messages API and decodes the structured
/// coaching report. Swift has no official Anthropic SDK, so this is a plain
/// URLSession call.
enum CoachClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-4-8"

    static func coach(analysis: SquatAnalysis, videoURL: URL) async throws -> CoachReport {
        guard let apiKey = CoachKeyStore.load(), !apiKey.isEmpty else {
            throw CoachError.missingKey
        }
        let keyframes = try await KeyframeExtractor.keyframes(for: analysis, videoURL: videoURL)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "system": CoachPrompt.systemPrompt(),
            "messages": [[
                "role": "user",
                "content": CoachPrompt.userContent(analysis: analysis, keyframes: keyframes),
            ]],
            "output_config": ["format": [
                "type": "json_schema",
                "schema": CoachPrompt.outputSchema,
            ]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = errorMessage(from: data) ?? "no details"
            throw CoachError.http(status, message)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [[String: Any]]
        else { throw CoachError.badResponse }

        if payload["stop_reason"] as? String == "refusal" {
            let details = payload["stop_details"] as? [String: Any]
            throw CoachError.refused(details?["explanation"] as? String)
        }
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let json = text.data(using: .utf8)
        else { throw CoachError.badResponse }
        return try JSONDecoder().decode(CoachReport.self, from: json)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }
}
