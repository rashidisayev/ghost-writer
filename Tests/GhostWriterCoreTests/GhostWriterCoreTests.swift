import XCTest
@testable import GhostWriterCore

// MARK: - ScopeResolver

final class ScopeResolverTests: XCTestCase {

    func testParagraphScopeStopsAtBlankLine() throws {
        let text = "First paragraph here.\n\nSecond paragraph that we care about.\n\nThird one."
        let caret = text.distance(
            from: text.startIndex,
            to: try XCTUnwrap(text.range(of: "care about")).lowerBound
        )
        let scope = try XCTUnwrap(ScopeResolver.paragraph(in: text, caret: caret))
        XCTAssertEqual(scope.body, "Second paragraph that we care about.")
    }

    func testSingleLineFieldIsTreatedAsWholeParagraph() throws {
        let text = "this is one long single line field value with no breaks"
        let scope = try XCTUnwrap(ScopeResolver.paragraph(in: text, caret: 10))
        XCTAssertEqual(scope.body, text)
    }

    func testRejectsTooShortBody() {
        XCTAssertNil(ScopeResolver.paragraph(in: "hi", caret: 1))
    }

    /// The range must map back onto the original buffer exactly, or the write
    /// lands in the wrong place.
    func testRangeMapsBackToBuffer() throws {
        let text = "AAAA\n\nTarget paragraph text here.\n\nBBBB"
        let scope = try XCTUnwrap(ScopeResolver.paragraph(in: text, caret: 10))
        let chars = Array(text)
        let slice = String(chars[scope.range.location..<(scope.range.location + scope.range.length)])
        XCTAssertEqual(slice, scope.body)
    }

    func testCaretAtBufferEndResolves() throws {
        let text = "Some reasonably long paragraph of text."
        let scope = try XCTUnwrap(ScopeResolver.paragraph(in: text, caret: text.count))
        XCTAssertEqual(scope.body, text)
    }
}

// MARK: - DiffEngine

final class DiffEngineTests: XCTestCase {

    func testDetectsWordSubstitution() {
        let diff = DiffEngine.wordDiff("the quick brown fox", "the slow brown fox")
        XCTAssertTrue(diff.hasMeaningfulChanges)
        let inserted = diff.ops.compactMap { op -> String? in
            if case let .insert(s) = op { return s } else { return nil }
        }
        XCTAssertTrue(inserted.joined().contains("slow"))
    }

    /// A single changed comma is noise — showing a card for it trains users to
    /// reflexively hit Esc.
    func testSuppressesTrivialChange() {
        let diff = DiffEngine.wordDiff("hello there world", "hello there, world")
        XCTAssertFalse(diff.hasMeaningfulChanges)
    }

    func testIdenticalTextHasNoChanges() {
        let diff = DiffEngine.wordDiff("unchanged text", "unchanged text")
        XCTAssertFalse(diff.hasMeaningfulChanges)
    }

    /// Tokenization keeps trailing whitespace with each word so reassembly is
    /// lossless — otherwise accepting a rewrite mangles spacing.
    func testTokenizeIsLossless() {
        let input = "  spaced   out\ntext here  "
        XCTAssertEqual(DiffEngine.tokenize(input).joined(), input)
    }

    func testCoalesceMergesAdjacentSameKindOps() {
        let ops: [WordDiff.Op] = [.equal("a "), .equal("b "), .insert("c "), .insert("d ")]
        let merged = DiffEngine.coalesce(ops)
        XCTAssertEqual(merged, [.equal("a b "), .insert("c d ")])
    }
}

// MARK: - CredentialHeuristics

final class CredentialHeuristicsTests: XCTestCase {

    func testDetectsCredentials() {
        let samples = [
            "my key is sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345",
            "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123",
            "AKIAIOSFODNN7EXAMPLE is the access key",
            "password: hunter2000secret",
            "-----BEGIN RSA PRIVATE KEY-----",
            "card 4111 1111 1111 1111 on file",
        ]
        for sample in samples {
            XCTAssertTrue(
                CredentialHeuristics.looksSensitive(sample),
                "should have flagged: \(sample)"
            )
        }
    }

    func testAllowsOrdinaryProse() {
        let samples = [
            "Hi Sarah, could you review the deck before Thursday? Thanks.",
            "The meeting is at 3pm in room 402.",
            "I think we should ship it — the numbers look good.",
            "Please find the attached report and let me know your thoughts.",
        ]
        for sample in samples {
            XCTAssertFalse(
                CredentialHeuristics.looksSensitive(sample),
                "should NOT have flagged: \(sample)"
            )
        }
    }
}

// MARK: - PolicyEngine

final class PolicyEngineTests: XCTestCase {

    private let editableInTextEdit = FocusDescriptor(
        bundleIdentifier: "com.apple.TextEdit", isSecureField: false, roleIsEditable: true)

    func testBlocksSecureFields() {
        let focus = FocusDescriptor(
            bundleIdentifier: "com.apple.Safari", isSecureField: true, roleIsEditable: true)
        XCTAssertEqual(PolicyEngine().evaluate(focus), .denySecureField)
    }

    func testBlocksPasswordManagers() {
        let focus = FocusDescriptor(
            bundleIdentifier: "com.1password.1password",
            isSecureField: false, roleIsEditable: true)
        XCTAssertEqual(
            PolicyEngine().evaluate(focus),
            .denyExcludedApp("com.1password.1password")
        )
    }

    func testBlocksTerminals() {
        let focus = FocusDescriptor(
            bundleIdentifier: "com.apple.Terminal", isSecureField: false, roleIsEditable: true)
        XCTAssertEqual(PolicyEngine().evaluate(focus), .denyExcludedApp("com.apple.Terminal"))
    }

    func testBlocksNonEditable() {
        let focus = FocusDescriptor(
            bundleIdentifier: "com.apple.TextEdit", isSecureField: false, roleIsEditable: false)
        XCTAssertEqual(PolicyEngine().evaluate(focus), .denyNotEditable)
    }

    func testAllowsOrdinaryEditableField() {
        XCTAssertEqual(PolicyEngine().evaluate(editableInTextEdit), .allow)
    }

    func testRespectsPause() {
        XCTAssertEqual(PolicyEngine(isPaused: true).evaluate(editableInTextEdit), .denyPaused)
    }
}

final class ProviderErrorTests: XCTestCase {
    func testQuota429IsNotRetryable() {
        let err = ProviderError.http(
            status: 429, retryAfter: nil,
            message: "You exceeded your current quota",
            code: ProviderError.quotaCode
        )
        XCTAssertFalse(err.isRetryable)
        XCTAssertTrue(err.errorDescription!.contains("no API credit"))
    }

    func testPlain429StaysRetryable() {
        let err = ProviderError.http(
            status: 429, retryAfter: "2", message: nil, code: "rate_limit_exceeded"
        )
        XCTAssertTrue(err.isRetryable)
        XCTAssertTrue(err.errorDescription!.contains("Rate limited"))
    }

    func testProjectKeyIsDetectedAsCredential() {
        // sk-proj- keys contain hyphens, which the generic sk- pattern misses.
        XCTAssertTrue(CredentialHeuristics.looksSensitive(
            "my key is sk-proj-abc123DEF456_ghi-789JKLmno0pqrs"
        ))
    }
}

final class UnicodeRangeTests: XCTestCase {
    /// The contract that matters: the range ScopeResolver returns is handed to
    /// the AX writer, and AX ranges are UTF-16. If this fails, a rewrite is
    /// written to the wrong offset and eats neighbouring text.
    private func assertRangeMatchesBody(_ text: String, line: UInt = #line) {
        guard let scope = ScopeResolver.paragraph(in: text, caret: text.utf16.count) else {
            return XCTFail("no scope resolved", line: line)
        }
        let ns = text as NSString
        XCTAssertTrue(
            NSMaxRange(scope.range) <= ns.length,
            "range overruns buffer", line: line
        )
        XCTAssertEqual(
            ns.substring(with: scope.range), scope.body,
            "range does not address the body it came with", line: line
        )
    }

    func testAsciiRangeIsCorrect() {
        assertRangeMatchesBody("This is a plain ASCII paragraph, long enough to qualify.")
    }

    func testEmojiRangeIsCorrect() {
        assertRangeMatchesBody("Shipping this today 🚀 and it should read correctly.")
    }

    func testCombiningMarksRangeIsCorrect() {
        // "e" + combining acute: one grapheme, two UTF-16 units.
        assertRangeMatchesBody("Le cafe\u{0301} est ouvert et la terrasse est pleine.")
    }

    func testCyrillicRangeIsCorrect() {
        assertRangeMatchesBody("Это довольно длинный абзац для проверки диапазона.")
    }
}

final class ModelConfigurationTests: XCTestCase {
    /// Guards a costly regression. Omitting reasoning.effort defaults GPT-5.6
    /// to "medium", which spends reasoning tokens and seconds on a style edit,
    /// and "minimal" — valid on earlier families — is rejected by 5.6. Both
    /// mistakes are invisible until the latency or the bill shows up.
    func testEffortValuesAreValidAndCheap() {
        let allowed: Set<String> = ["none", "low"]
        for level in Aggressiveness.allCases {
            XCTAssertTrue(
                allowed.contains(level.effort),
                "\(level) uses effort '\(level.effort)'; only none/low keep a rewrite interactive"
            )
        }
    }

    func testModelIdentifiersArePinned() {
        XCTAssertEqual(RewriteModel.sol.apiIdentifier, "gpt-5.6-sol")
        XCTAssertEqual(RewriteModel.terra.apiIdentifier, "gpt-5.6-terra")
        XCTAssertEqual(RewriteModel.luna.apiIdentifier, "gpt-5.6-luna")
    }

    func testEveryModelHasADistinctDisplayName() {
        let names = Set(RewriteModel.allCases.map(\.displayName))
        XCTAssertEqual(names.count, RewriteModel.allCases.count)
    }

    /// max_output_tokens is derived from this; a zero would starve the request.
    func testTokenEstimateHasAFloor() {
        let request = RewriteRequest(
            text: "", context: nil, tone: .neutral, aggressiveness: .balanced, model: .terra
        )
        XCTAssertGreaterThanOrEqual(request.approxInputTokens, 16)
    }
}
