import Foundation

/// Per-app quirk table. Chromium, Electron, and WebKit change their
/// accessibility trees regularly, and the attributes needed to turn those trees
/// on are private and undocumented — a Slack update can break text reading on a
/// Tuesday. In v1 this table is compiled in; docs/05 §8 specifies making it a
/// remote-updatable signed payload before this ships to users.
public struct AppQuirks: Sendable {
    /// Electron/Chromium build their AX tree lazily. Ask for it, or the tree is
    /// empty and every read silently returns nothing.
    public var needsManualAccessibility: Bool = false
    public var needsEnhancedUI: Bool = false
    /// AX writes report success and silently no-op in most web content.
    public var preferPasteStrategy: Bool = false
    /// How long to wait after ⌘V before restoring the pasteboard.
    public var pasteSettleMS: Int = 120

    public init(
        needsManualAccessibility: Bool = false,
        needsEnhancedUI: Bool = false,
        preferPasteStrategy: Bool = false,
        pasteSettleMS: Int = 120
    ) {
        self.needsManualAccessibility = needsManualAccessibility
        self.needsEnhancedUI = needsEnhancedUI
        self.preferPasteStrategy = preferPasteStrategy
        self.pasteSettleMS = pasteSettleMS
    }
}

public enum AXCompat {
    private static let table: [String: AppQuirks] = [
        // Electron
        "com.tinyspeck.slackmacgap": AppQuirks(
            needsManualAccessibility: true, preferPasteStrategy: true, pasteSettleMS: 200),
        "com.hnc.Discord": AppQuirks(
            needsManualAccessibility: true, preferPasteStrategy: true, pasteSettleMS: 200),
        "com.microsoft.teams2": AppQuirks(
            needsManualAccessibility: true, preferPasteStrategy: true, pasteSettleMS: 250),
        "notion.id": AppQuirks(
            needsManualAccessibility: true, preferPasteStrategy: true, pasteSettleMS: 200),
        "com.microsoft.VSCode": AppQuirks(
            needsManualAccessibility: true, preferPasteStrategy: true, pasteSettleMS: 200),

        // Chromium
        "com.google.Chrome": AppQuirks(
            needsManualAccessibility: true, needsEnhancedUI: true, preferPasteStrategy: true, pasteSettleMS: 150),
        "company.thebrowser.Browser": AppQuirks(
            needsManualAccessibility: true, needsEnhancedUI: true, preferPasteStrategy: true, pasteSettleMS: 150),
        "com.microsoft.edgemac": AppQuirks(
            needsManualAccessibility: true, needsEnhancedUI: true, preferPasteStrategy: true, pasteSettleMS: 150),
        "com.brave.Browser": AppQuirks(
            needsManualAccessibility: true, needsEnhancedUI: true, preferPasteStrategy: true, pasteSettleMS: 150),

        // WebKit — behaves differently from Chromium
        "com.apple.Safari": AppQuirks(preferPasteStrategy: true, pasteSettleMS: 120),

        // Native — the easy cases
        "com.apple.TextEdit": AppQuirks(),
        "com.apple.mail": AppQuirks(pasteSettleMS: 150),
        "com.apple.Notes": AppQuirks(preferPasteStrategy: true, pasteSettleMS: 150),
    ]

    /// Unknown apps get the conservative default: paste strategy, which is the
    /// only one that works everywhere and preserves the host's undo stack, plus
    /// both priming attributes.
    ///
    /// Priming unknown apps matters more than the table does. The table can only
    /// ever list Electron apps someone thought to add; every one that isn't in it
    /// — and there are far more of those — would otherwise be asked for a tree it
    /// never built, and read as "no text field focused". Both attributes are
    /// private no-ops on apps that don't implement them, so the cost of setting
    /// them speculatively is nil.
    public static func quirks(for bundleID: String?) -> AppQuirks {
        guard let bundleID, let known = table[bundleID] else {
            return AppQuirks(
                needsManualAccessibility: true,
                needsEnhancedUI: true,
                preferPasteStrategy: true
            )
        }
        return known
    }
}
