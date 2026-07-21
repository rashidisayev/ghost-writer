import XCTest
@testable import GhostWriterAccessibility

/// The quirk table is a pure lookup, so it tests cleanly without a display,
/// an AX grant, or a running app — which is exactly what makes it worth
/// covering in CI, where none of those exist.
final class AXCompatTests: XCTestCase {

    /// The bug this exists to prevent: unknown apps once received no priming at
    /// all, so every Electron app absent from the table read as "no text field
    /// focused". The table can only list apps somebody thought to add; the
    /// default is what covers the rest.
    func testUnknownAppsArePrimedSpeculatively() {
        let quirks = AXCompat.quirks(for: "com.example.some.unlisted.electron.app")
        XCTAssertTrue(quirks.needsManualAccessibility)
        XCTAssertTrue(quirks.needsEnhancedUI)
        XCTAssertTrue(quirks.preferPasteStrategy)
    }

    func testNilBundleIDGetsTheSafeDefault() {
        let quirks = AXCompat.quirks(for: nil)
        XCTAssertTrue(quirks.needsManualAccessibility)
        XCTAssertTrue(quirks.preferPasteStrategy)
    }

    func testElectronAppsRequestTheirTree() {
        for bundle in ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2"] {
            XCTAssertTrue(
                AXCompat.quirks(for: bundle).needsManualAccessibility,
                "\(bundle) is Electron and needs AXManualAccessibility"
            )
        }
    }

    /// Chromium once relied on EnhancedUI alone, which was not enough to make
    /// it build a tree.
    func testChromiumBrowsersRequestBothAttributes() {
        for bundle in ["com.google.Chrome", "company.thebrowser.Browser",
                       "com.microsoft.edgemac", "com.brave.Browser"] {
            let quirks = AXCompat.quirks(for: bundle)
            XCTAssertTrue(quirks.needsManualAccessibility, "\(bundle) needs manual accessibility")
            XCTAssertTrue(quirks.needsEnhancedUI, "\(bundle) needs enhanced UI")
        }
    }

    /// Web content silently no-ops AX writes, so these must never fall back to
    /// the direct-write path.
    func testWebContentPrefersPasting() {
        for bundle in ["com.apple.Safari", "com.google.Chrome", "com.tinyspeck.slackmacgap"] {
            XCTAssertTrue(AXCompat.quirks(for: bundle).preferPasteStrategy, "\(bundle)")
        }
    }

    func testPasteSettleIsSaneEverywhere() {
        for bundle in ["com.apple.TextEdit", "com.apple.mail", "com.google.Chrome",
                       "com.tinyspeck.slackmacgap", "com.unknown.app"] {
            let ms = AXCompat.quirks(for: bundle).pasteSettleMS
            XCTAssertGreaterThanOrEqual(ms, 100, "\(bundle) restores the pasteboard too eagerly")
            XCTAssertLessThanOrEqual(ms, 500, "\(bundle) holds the pasteboard too long")
        }
    }
}
