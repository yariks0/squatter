import Foundation

enum CoachError: LocalizedError {
    case unauthenticated
    case http(Int, String)
    case refused(String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthenticated:
            "Sign in again to get AI coaching."
        case let .http(status, message):
            "The coaching request failed (HTTP \(status)): \(message)"
        case let .refused(explanation):
            explanation ?? "The model declined to assess this set."
        case .badResponse:
            "Could not read the coaching response."
        }
    }
}

/// Sends the set to the backend coach proxy, which holds the Anthropic key
/// and forwards to the Messages API. The request body is still built here —
/// `CoachPrompt` embeds live analysis thresholds, so keeping it on the
/// client avoids a rotting server duplicate — and the response is Anthropic's
/// verbatim, so parsing is unchanged.
enum CoachClient {
    private static let endpoint = BackendConfig.baseURL.appendingPathComponent("v1/coach")
    private static let model = "claude-opus-4-8"

    static func coach(analysis: SquatAnalysis, videoURL: URL) async throws -> CoachReport {
        guard let token = AuthTokenStore.load(), !token.isEmpty else {
            throw CoachError.unauthenticated
        }
        let keyframes = try await KeyframeExtractor.keyframes(for: analysis, videoURL: videoURL)

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 24000,
            // Streamed, and not for progressive display: a buffered coach call
            // sits silent for ~90 s while the model works, and a connection
            // idle that long gets torn down in transit (a QUIC/HTTP-3 idle
            // timeout at the TLS edge killed one at 58 s with a bare 504).
            // SSE keeps bytes moving, so nothing on the path sees an idle
            // connection. The backend relays the events unbuffered.
            "stream": true,
            "thinking": ["type": "adaptive"],
            "system": CoachPrompt.systemPrompt(activity: analysis.kind),
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CoachError.unauthenticated }
        guard status == 200 else {
            var data = Data()
            for try await byte in stream { data.append(byte) }
            throw CoachError.http(status, errorMessage(from: data) ?? "no details")
        }

        let text = try await assembledText(from: stream)
        guard let json = text.data(using: .utf8) else { throw CoachError.badResponse }
        let report = try JSONDecoder().decode(CoachReport.self, from: json)
        guard let sane = report.sanitized() else { throw CoachError.badResponse }
        return sane
    }

    /// Rebuilds the report JSON from the SSE event stream — the streaming
    /// equivalent of reading `content[.type == "text"].text` off a whole
    /// response.
    ///
    /// Only text blocks are accumulated. Adaptive thinking emits its own
    /// blocks in the same stream, and folding those into the buffer would
    /// corrupt the JSON.
    private static func assembledText(from stream: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        var textBlocks: Set<Int> = []
        var refusal: String??

        for try await line in stream.lines {
            guard line.hasPrefix("data:") else { continue } // skip `event:`/keep-alives
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch event["type"] as? String {
            case "content_block_start":
                if let index = event["index"] as? Int,
                   let block = event["content_block"] as? [String: Any],
                   block["type"] as? String == "text" {
                    textBlocks.insert(index)
                }
            case "content_block_delta":
                if let index = event["index"] as? Int, textBlocks.contains(index),
                   let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let chunk = delta["text"] as? String {
                    text += chunk
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "refusal" {
                    let details = delta["stop_details"] as? [String: Any]
                    refusal = .some(details?["explanation"] as? String)
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw CoachError.http(200, error?["message"] as? String ?? "stream error")
            default:
                break
            }
        }
        if case let .some(explanation) = refusal { throw CoachError.refused(explanation) }
        return text
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }
}
