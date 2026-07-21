import Foundation

/// Send-side guard. The read has already happened by the time this runs; this
/// decides whether anything leaves the machine. Biased heavily toward false
/// positives — silently skipping a rewrite costs nothing, leaking a key is
/// unrecoverable.
public enum CredentialHeuristics {

    private static let patterns: [String] = [
        #"sk-ant-[A-Za-z0-9_\-]{16,}"#,          // Anthropic
        // Project keys (`sk-proj-…`) contain hyphens and underscores, so the
        // alphanumeric-only pattern below never matches them.
        #"sk-proj-[A-Za-z0-9_\-]{20,}"#,          // OpenAI project key
        #"sk-[A-Za-z0-9]{32,}"#,                  // OpenAI legacy / generic
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,           // GitHub
        #"AKIA[0-9A-Z]{16}"#,                     // AWS access key id
        #"AIza[0-9A-Za-z_\-]{35}"#,               // Google API key
        #"xox[baprs]-[0-9A-Za-z\-]{10,}"#,        // Slack
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,   // PEM
        #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\."#, // JWT
        #"(?i)\b(password|passwd|secret|api[_\- ]?key|token|bearer)\b\s*[:=]\s*\S{6,}"#,
        #"\b(?:\d[ \-]?){13,19}\b"#,              // card-shaped digit run
    ]

    private static let compiled: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    public static func looksSensitive(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in compiled where regex.firstMatch(in: text, range: range) != nil {
            return true
        }
        return highEntropyRun(in: text)
    }

    /// A long unbroken run of mixed-case alphanumerics with no spaces is a
    /// credential far more often than it is prose.
    private static func highEntropyRun(in text: String) -> Bool {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            guard token.count >= 28 else { continue }
            let hasUpper = token.contains { $0.isUppercase }
            let hasLower = token.contains { $0.isLowercase }
            let hasDigit = token.contains { $0.isNumber }
            if hasUpper && hasLower && hasDigit { return true }
        }
        return false
    }
}
