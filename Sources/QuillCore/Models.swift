import Foundation

// MARK: - Tone

public enum ToneProfile: String, Sendable, CaseIterable, Codable {
    case neutral, professional, friendly, concise

    public var displayName: String {
        switch self {
        case .neutral: "Neutral"
        case .professional: "Professional"
        case .friendly: "Friendly"
        case .concise: "Concise"
        }
    }

    public var instructions: String {
        switch self {
        case .neutral:
            "Match the author's existing voice and register. Do not impose a style of your own."
        case .professional:
            "Use a clear, professional register suitable for workplace writing. Avoid slang and filler."
        case .friendly:
            "Use a warm, conversational register. Keep contractions and the author's informality."
        case .concise:
            "Prefer short sentences and plain words. Cut hedging and redundancy aggressively."
        }
    }
}

// MARK: - Aggressiveness

public enum Aggressiveness: String, Sendable, CaseIterable, Codable {
    case light, balanced, bold

    public var displayName: String {
        switch self {
        case .light: "Light — grammar only"
        case .balanced: "Balanced"
        case .bold: "Bold — rewrite freely"
        }
    }

    public var instruction: String {
        switch self {
        case .light:
            """
            Correct grammar, spelling, and punctuation only. Do not change word \
            choice, sentence structure, or sentence boundaries.
            """
        case .balanced:
            """
            Correct grammar, spelling, and punctuation. Improve clarity and word \
            choice. You may merge or split sentences where it genuinely improves \
            readability.
            """
        case .bold:
            """
            Rewrite freely for maximum clarity and impact. You may restructure the \
            passage and cut redundant sentences, as long as no meaning is lost.
            """
        }
    }

    /// OpenAI `reasoning.effort`.
    ///
    /// Deliberately capped at "low". Omitting this field defaults GPT-5.6 to
    /// "medium", which spends reasoning tokens — latency and money — on what is
    /// a style edit, not a reasoning problem. "minimal" is not valid on 5.6.
    public var effort: String {
        switch self {
        case .light: "none"
        case .balanced: "none"
        case .bold: "low"
        }
    }
}

// MARK: - Model

public enum RewriteModel: String, Sendable, CaseIterable, Codable {
    case sol = "gpt-5.6-sol"
    case terra = "gpt-5.6-terra"
    case luna = "gpt-5.6-luna"

    public var apiIdentifier: String { rawValue }

    public var displayName: String {
        switch self {
        case .sol: "GPT-5.6 Sol — best quality"
        case .terra: "GPT-5.6 Terra — balanced"
        case .luna: "GPT-5.6 Luna — fastest"
        }
    }
}

// MARK: - Request / result

public struct RewriteRequest: Sendable {
    public let text: String
    public let context: String?
    public let tone: ToneProfile
    public let aggressiveness: Aggressiveness
    public let model: RewriteModel

    public init(
        text: String,
        context: String?,
        tone: ToneProfile,
        aggressiveness: Aggressiveness,
        model: RewriteModel
    ) {
        self.text = text
        self.context = context
        self.tone = tone
        self.aggressiveness = aggressiveness
        self.model = model
    }

    /// Rough 4-chars-per-token heuristic; only used to bound `max_tokens`.
    public var approxInputTokens: Int {
        max(16, (text.count + (context?.count ?? 0)) / 4)
    }

    public var cacheKey: Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(context)
        hasher.combine(tone)
        hasher.combine(aggressiveness)
        hasher.combine(model)
        hasher.combine(PromptVersion.current)
        return hasher.finalize()
    }
}

public enum PromptVersion {
    /// Bump on any prompt change — it participates in the cache key.
    public static let current = 7
}

public struct RewriteResult: Sendable {
    public let text: String
    public let outputTokens: Int?

    public init(text: String, outputTokens: Int? = nil) {
        self.text = text
        self.outputTokens = outputTokens
    }
}

public enum RewriteEvent: Sendable {
    case delta(String)
    case usage(output: Int)
    case done
}

// MARK: - Provider

public protocol RewriteProvider: Sendable {
    func rewrite(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error>
}

public enum ProviderError: Error, LocalizedError {
    case missingKey
    case badResponse
    case http(status: Int, retryAfter: String?, message: String?, code: String?)
    case stream(String)

    /// OpenAI returns 429 for two unrelated conditions: real rate limiting, and
    /// an account with no credit. Only `error.code` separates them, and telling
    /// someone to "wait a moment" when their balance is zero sends them off to
    /// debug the wrong problem entirely.
    public static let quotaCode = "insufficient_quota"

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            "No API key. Open Quill Settings and paste an OpenAI API key."
        case .badResponse:
            "Unexpected response from the OpenAI API."
        case let .http(status, _, message, code):
            switch status {
            case 401: "Invalid API key (401). Check the key in Quill Settings."
            case 403: "This API key lacks permission for the selected model (403)."
            case 404: "Model not found (404). Pick a different model in Settings."
            case 429 where code == Self.quotaCode:
                "This OpenAI account has no API credit. Add a balance at platform.openai.com → Billing; a ChatGPT subscription doesn't cover API usage."
            case 429: "Rate limited (429). Wait a moment and try again."
            case 500...599: "OpenAI API error (\(status)). Try again shortly."
            default: message.map { "API error \(status): \($0)" } ?? "API error \(status)."
            }
        case let .stream(message):
            "Stream error: \(message)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        // An empty balance is not a transient condition — retrying it just
        // spends the user's time to arrive at the same 429.
        case let .http(status, _, _, code):
            code != Self.quotaCode && (status == 429 || (500...599).contains(status))
        case .badResponse, .stream: true
        case .missingKey: false
        }
    }
}
