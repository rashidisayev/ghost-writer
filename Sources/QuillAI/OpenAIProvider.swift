import Foundation
import QuillCore
import QuillStorage

/// Talks to OpenAI's Responses API (`/v1/responses`) directly rather than
/// pulling in an SDK. See docs/04-project-structure.md §3 for why that's the
/// right call in a process holding Accessibility permission — every dependency
/// here is code running next to the user's keystrokes.
public actor OpenAIProvider: RewriteProvider {

    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    private let session: URLSession
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil                        // never cache request bodies
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        cfg.httpMaximumConnectionsPerHost = 2     // keep-alive, reuse the TLS session
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv13
        self.session = URLSession(configuration: cfg)
        self.keychain = keychain
    }

    public nonisolated func rewrite(
        _ r: RewriteRequest
    ) -> AsyncThrowingStream<RewriteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.stream(r, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        _ r: RewriteRequest,
        into out: AsyncThrowingStream<RewriteEvent, Error>.Continuation
    ) async throws {
        guard let key = try keychain.apiKey(), !key.isEmpty else {
            throw ProviderError.missingKey
        }

        // Bound the output: a rewrite is roughly the length of its input.
        // This budget is shared with reasoning tokens, so it has to clear the
        // floor the model needs before it emits any text at all.
        let maxOutputTokens = max(256, min(4096, Int(Double(r.approxInputTokens) * 1.4) + 64))

        let body: [String: Any] = [
            "model": r.model.apiIdentifier,
            "max_output_tokens": maxOutputTokens,
            "stream": true,
            "input": [
                ["role": "system", "content": PromptBuilder.system(
                    tone: r.tone, aggressiveness: r.aggressiveness
                )],
                ["role": "user", "content": PromptBuilder.user(r)],
            ],
            // Omitting this defaults GPT-5.6 to "medium" — reasoning tokens and
            // seconds of latency spent on what is a style edit. See
            // Aggressiveness.effort.
            "reasoning": ["effort": r.aggressiveness.effort],
            // The panel shows plain text; asking for anything else just invites
            // the model to wrap the rewrite in markdown fences we'd have to strip.
            "text": ["format": ["type": "text"]],
            "store": false,
        ]

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard http.statusCode == 200 else {
            // Drain a little of the error body for a usable message.
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 800 { break }
            }
            let parsed = Self.extractError(detail)
            throw ProviderError.http(
                status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "retry-after"),
                message: parsed.message,
                code: parsed.code
            )
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "response.output_text.delta":
                if let text = obj["delta"] as? String {
                    out.yield(.delta(text))
                }
            case "response.completed":
                if let usage = (obj["response"] as? [String: Any])?["usage"] as? [String: Any],
                   let outTok = usage["output_tokens"] as? Int {
                    out.yield(.usage(output: outTok))
                }
                out.yield(.done)
            case "response.incomplete", "response.failed":
                // Hitting the token ceiling arrives here, not as an HTTP error —
                // it would otherwise look like a silently truncated rewrite.
                let resp = obj["response"] as? [String: Any]
                let reason = (resp?["incomplete_details"] as? [String: Any])?["reason"] as? String
                    ?? (resp?["error"] as? [String: Any])?["message"] as? String
                throw ProviderError.stream(reason ?? "response did not complete")
            case "error":
                throw ProviderError.stream(obj["message"] as? String ?? "unknown")
            default:
                continue
            }
        }
    }

    private static func extractError(_ raw: String) -> (message: String?, code: String?) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return (nil, nil) }
        return (err["message"] as? String, err["code"] as? String)
    }

    /// Cheap credential check for the Settings screen: one minimal request.
    public func validateKey(_ key: String, model: RewriteModel) async -> Result<Void, Error> {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model.apiIdentifier,
            "max_output_tokens": 16,
            "reasoning": ["effort": "none"],
            "input": "hi",
            "store": false,
        ])

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(ProviderError.badResponse)
            }
            // A 200 means the key and model are both usable. The response may
            // well be `incomplete` at this token budget — that's still a valid
            // key, which is the only thing being checked here.
            guard http.statusCode == 200 else {
                let parsed = Self.extractError(String(data: data, encoding: .utf8) ?? "")
                return .failure(ProviderError.http(
                    status: http.statusCode,
                    retryAfter: nil,
                    message: parsed.message,
                    code: parsed.code
                ))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
