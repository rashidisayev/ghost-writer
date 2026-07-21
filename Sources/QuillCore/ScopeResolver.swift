import Foundation

/// The paragraph around the caret is the unit of rewriting. Scoping to it is
/// what makes the latency budget, the cost model, and the privacy story all
/// work at once — see docs/01-product-spec.md.
public struct TextScope: Sendable {
    /// The paragraph to rewrite.
    public let body: String
    /// Character range of `body` within the full buffer.
    public let range: NSRange
    /// Neighbouring paragraphs, sent as read-only context.
    public let surroundingContext: String?

    public init(body: String, range: NSRange, surroundingContext: String?) {
        self.body = body
        self.range = range
        self.surroundingContext = surroundingContext
    }
}

public enum ScopeResolver {

    /// Minimum body length worth sending. Below this a rewrite is noise.
    public static let minimumBodyLength = 15

    /// Extracts the paragraph containing `caret`, plus up to `contextChars`
    /// of neighbouring text as non-rewritable context.
    public static func paragraph(
        in text: String,
        caret: Int,
        contextChars: Int = 600
    ) -> TextScope? {
        guard !text.isEmpty else { return nil }

        // Everything here is in UTF-16 code units, NOT Characters.
        //
        // `range` below is handed to the AX writer, and AX ranges are UTF-16.
        // Indexing by Character instead desynchronises the two the moment the
        // text contains an emoji (2 units, 1 Character) or a combining mark —
        // the rewrite is then written at the wrong offset and overwrites the
        // neighbouring text. ASCII and Cyrillic hide the bug; emoji expose it.
        let units = Array(text.utf16)
        let clamped = min(max(caret, 0), units.count)

        let newline = UInt16(0x0A)
        let space = UInt16(0x20)

        // A paragraph is delimited by a blank line (\n\n) or buffer edge. In
        // single-line fields there is no delimiter, so the whole value is one
        // paragraph — which is the behaviour we want in a search box or a
        // Slack composer.
        var start = clamped
        while start > 0 {
            if units[start - 1] == newline, start >= 2, units[start - 2] == newline { break }
            start -= 1
        }
        var end = clamped
        while end < units.count {
            if units[end] == newline, end + 1 < units.count, units[end + 1] == newline { break }
            end += 1
        }

        var bodyStart = start
        while bodyStart < end, units[bodyStart] == newline || units[bodyStart] == space {
            bodyStart += 1
        }
        var bodyEnd = end
        while bodyEnd > bodyStart,
              units[bodyEnd - 1] == newline || units[bodyEnd - 1] == space {
            bodyEnd -= 1
        }
        guard bodyEnd > bodyStart else { return nil }

        let body = String(decoding: units[bodyStart..<bodyEnd], as: UTF16.self)
        // A human-facing threshold, so Characters is the right unit here — one
        // emoji is one character to the person who typed it.
        guard body.count >= minimumBodyLength else { return nil }

        let before = String(decoding: units[safeStart(units, bodyStart - contextChars)..<bodyStart],
                            as: UTF16.self)
        let after = String(decoding: units[bodyEnd..<safeEnd(units, bodyEnd + contextChars)],
                           as: UTF16.self)
        let context = (before + "…" + after).trimmingCharacters(in: .whitespacesAndNewlines)

        return TextScope(
            body: body,
            range: NSRange(location: bodyStart, length: bodyEnd - bodyStart),
            surroundingContext: context.count > 2 ? context : nil
        )
    }

    /// Context is sliced at an arbitrary offset, which can land between the two
    /// halves of a surrogate pair and decode to U+FFFD. Nudge inward — losing a
    /// character of context is invisible, a replacement glyph in the prompt is
    /// not. The body's own bounds are paragraph edges and never need this.
    private static func safeStart(_ units: [UInt16], _ index: Int) -> Int {
        let i = min(max(index, 0), units.count)
        guard i < units.count, isLowSurrogate(units[i]) else { return i }
        return i + 1
    }

    private static func safeEnd(_ units: [UInt16], _ index: Int) -> Int {
        let i = min(max(index, 0), units.count)
        guard i > 0, i < units.count, isHighSurrogate(units[i - 1]) else { return i }
        return i - 1
    }

    private static func isHighSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDBFF).contains(u) }
    private static func isLowSurrogate(_ u: UInt16) -> Bool { (0xDC00...0xDFFF).contains(u) }
}
