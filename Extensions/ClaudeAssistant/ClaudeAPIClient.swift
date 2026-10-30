//
//  ClaudeAPIClient.swift
//  Code
//
//  Minimal streaming client for the Anthropic Messages API.
//

import Foundation

enum ClaudeAPIError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key configured. Add one in the Claude panel settings."
        case .http(let status, let message):
            return "Claude API error (\(status)): \(message)"
        case .invalidResponse:
            return "Invalid response from Claude API."
        }
    }
}

/// Events emitted while a response is streaming.
enum ClaudeStreamEvent {
    case textDelta(String)
    case toolUseStarted(id: String, name: String)
}

/// The fully assembled assistant turn once streaming has finished.
struct ClaudeTurnResult {
    /// Content blocks in API format, ready to be appended to the message history.
    var contentBlocks: [[String: Any]]
    var stopReason: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    var toolUses: [(id: String, name: String, input: [String: Any])] {
        contentBlocks.compactMap { block in
            guard block["type"] as? String == "tool_use",
                let id = block["id"] as? String,
                let name = block["name"] as? String
            else { return nil }
            return (id, name, block["input"] as? [String: Any] ?? [:])
        }
    }
}

final class ClaudeAPIClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamMessage(
        apiKey: String,
        model: String,
        maxTokens: Int,
        system: String,
        tools: [[String: Any]],
        messages: [[String: Any]],
        onEvent: @escaping @MainActor (ClaudeStreamEvent) -> Void
    ) async throws -> ClaudeTurnResult {
        guard !apiKey.isEmpty else { throw ClaudeAPIError.missingAPIKey }

        // Cache the (stable) system prompt + tool definitions to cut cost on long sessions.
        var cachedTools = tools
        if var last = cachedTools.popLast() {
            last["cache_control"] = ["type": "ephemeral"]
            cachedTools.append(last)
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": [
                ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]
            ],
            "tools": cachedTools,
            "messages": messages,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        if http.statusCode != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw ClaudeAPIError.http(status: http.statusCode, message: Self.errorMessage(from: raw))
        }

        // Accumulators, indexed by content block index.
        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var result = ClaudeTurnResult(contentBlocks: [])

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else { continue }

            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any],
                    let usage = message["usage"] as? [String: Any]
                {
                    result.inputTokens = usage["input_tokens"] as? Int ?? 0
                }

            case "content_block_start":
                guard let index = event["index"] as? Int,
                    let block = event["content_block"] as? [String: Any]
                else { continue }
                blocks[index] = block
                if block["type"] as? String == "tool_use" {
                    partialJSON[index] = ""
                    await onEvent(
                        .toolUseStarted(
                            id: block["id"] as? String ?? "", name: block["name"] as? String ?? ""))
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                    let delta = event["delta"] as? [String: Any]
                else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    let existing = blocks[index]?["text"] as? String ?? ""
                    blocks[index]?["text"] = existing + text
                    await onEvent(.textDelta(text))
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }

            case "content_block_stop":
                guard let index = event["index"] as? Int else { continue }
                if let json = partialJSON[index] {
                    let input: [String: Any] =
                        json.isEmpty
                        ? [:]
                        : (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                            as? [String: Any] ?? [:]
                    blocks[index]?["input"] = input
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    result.stopReason = delta["stop_reason"] as? String
                }
                if let usage = event["usage"] as? [String: Any] {
                    result.outputTokens = usage["output_tokens"] as? Int ?? 0
                }

            case "error":
                let message =
                    (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw ClaudeAPIError.http(status: 0, message: message)

            default:
                break
            }
        }

        result.contentBlocks = blocks.keys.sorted().compactMap { index in
            guard var block = blocks[index] else { return nil }
            // Drop empty text blocks; the API rejects them in history.
            if block["type"] as? String == "text", (block["text"] as? String ?? "").isEmpty {
                return nil
            }
            if block["type"] as? String == "tool_use", block["input"] == nil {
                block["input"] = [String: Any]()
            }
            return block
        }
        return result
    }

    private static func errorMessage(from raw: String) -> String {
        if let data = raw.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }
        return raw.isEmpty ? "No response body" : raw
    }
}
