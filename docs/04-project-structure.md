# Project Structure & Dependencies

## 1. Layout

Swift Package Manager modules inside a single Xcode project. The app target is a thin shell; everything testable lives in packages, which is what makes the AX and orchestration logic unit-testable without launching a GUI.

```
Ghost Writer/
├── Ghost Writer.xcodeproj
├── App/                                  # app target — thin
│   ├── GhostWriterApp.swift                    # @main, MenuBarExtra + Settings scenes
│   ├── AppDelegate.swift                 # LSUIElement lifecycle, login item
│   ├── Info.plist                        # LSUIElement=true, usage strings
│   ├── Ghost Writer.entitlements                # NOT sandboxed — see 09-risks.md
│   └── Resources/Assets.xcassets
│
├── Packages/
│   ├── GhostWriterCore/                        # pure logic, zero AppKit
│   │   ├── Model/
│   │   │   ├── RewriteRequest.swift
│   │   │   ├── RewriteResult.swift
│   │   │   ├── ToneProfile.swift
│   │   │   ├── FocusContext.swift
│   │   │   └── Settings.swift
│   │   ├── Orchestration/
│   │   │   ├── SuggestionOrchestrator.swift   # the actor
│   │   │   ├── SessionState.swift
│   │   │   └── Debouncer.swift
│   │   ├── Text/
│   │   │   ├── ScopeResolver.swift            # paragraph extraction
│   │   │   ├── DiffEngine.swift               # word-level diff
│   │   │   ├── LanguageDetector.swift         # NLLanguageRecognizer wrapper
│   │   │   └── CredentialHeuristics.swift
│   │   ├── Policy/
│   │   │   ├── PolicyEngine.swift
│   │   │   └── ExclusionList.swift
│   │   └── Cache/RewriteCache.swift
│   │
│   ├── GhostWriterAI/                          # provider abstraction
│   │   ├── RewriteProvider.swift         # protocol + capabilities
│   │   ├── PromptBuilder.swift           # system prompt assembly
│   │   ├── Claude/
│   │   │   ├── ClaudeProvider.swift
│   │   │   ├── ClaudeWire.swift          # Codable request/response
│   │   │   └── SSEParser.swift
│   │   ├── OpenAI/                       # v2 stub
│   │   └── Local/                        # v2 stub
│   │
│   ├── GhostWriterAccessibility/               # all AX in one place
│   │   ├── AXPermissions.swift
│   │   ├── FocusTracker.swift
│   │   ├── TextReader.swift
│   │   ├── TextWriter.swift
│   │   ├── ElementClassifier.swift       # native / web / electron / terminal
│   │   ├── BrowserURLResolver.swift
│   │   └── AXCompat.swift                # per-app quirk table
│   │
│   ├── GhostWriterInput/
│   │   ├── KeystrokeMonitor.swift        # CGEventTap, listen-only
│   │   ├── HotkeyManager.swift           # Carbon RegisterEventHotKey
│   │   └── SecureInputDetector.swift
│   │
│   ├── GhostWriterUI/
│   │   ├── MenuBar/
│   │   ├── Settings/                     # one SwiftUI view per tab
│   │   ├── Suggestion/
│   │   │   ├── SuggestionPanel.swift     # NSPanel subclass
│   │   │   ├── SuggestionView.swift      # SwiftUI content
│   │   │   ├── DiffTextView.swift
│   │   │   └── UnderlineOverlay.swift
│   │   └── Onboarding/
│   │
│   └── GhostWriterStorage/
│       ├── SettingsStore.swift           # UserDefaults + @Observable
│       ├── KeychainStore.swift
│       └── StatsStore.swift              # counters only, no content
│
├── Tests/
│   ├── GhostWriterCoreTests/                   # diff, scope, policy — fast, hermetic
│   ├── GhostWriterAITests/                     # SSE parsing against recorded fixtures
│   └── IntegrationTests/                 # drives TextEdit/Safari via AX
│
└── Tools/
    ├── ax-probe/                         # CLI: dump AX tree of frontmost app
    └── latency-bench/                    # CLI: p50/p95 harness per model
```

`Tools/ax-probe` is not optional polish. Debugging "why doesn't this work in app X" without a way to dump the live AX tree costs days.

## 2. Frameworks — Apple

| Framework | Use |
|---|---|
| **SwiftUI** | Settings, menu bar content, suggestion card body. `MenuBarExtra` for the status item. |
| **AppKit** | `NSPanel` (SwiftUI has no equivalent for non-activating floating overlays), `NSPasteboard`, `NSWorkspace`, `NSVisualEffectView` |
| **ApplicationServices / HIServices** | `AXUIElement`, `AXObserver`, `AXIsProcessTrustedWithOptions` |
| **CoreGraphics** | `CGEvent.tapCreate` for the debounce tap, `CGEvent` for synthetic `⌘V` |
| **Carbon** (`HIToolbox`) | `RegisterEventHotKey`. Deprecated in spirit, unreplaced in practice — `NSEvent.addGlobalMonitorForEvents` cannot consume the event, so it can't own a shortcut. |
| **NaturalLanguage** | `NLLanguageRecognizer` for on-device language tagging. Free, offline, no model download. |
| **ServiceManagement** | `SMAppService.mainApp.register()` for login item (replaces the deprecated `SMLoginItemSetEnabled`) |
| **Security** | Keychain Services for the API key |
| **UserNotifications** | Rare, non-intrusive alerts only (permission revoked, spend cap hit) |
| **OSLog** | Structured logging with `privacy: .private` on anything text-adjacent |

## 3. Third-party dependencies

Deliberately close to zero. Every dependency in an app with Accessibility and Input Monitoring permissions expands a very sensitive attack surface, and the supply-chain risk is not theoretical for a tool that reads everything you type.

| Package | Verdict | Reasoning |
|---|---|---|
| Anthropic SDK | **Not used** | No official Swift SDK. Write ~200 lines against `/v1/messages` with `URLSession`. Fewer lines than a wrapper would be. |
| `swift-collections` | **Yes** | `OrderedDictionary` for the LRU cache. Apple-maintained. |
| `KeychainAccess` | **No** | Keychain Services is ~40 lines for the two operations needed. Not worth a dependency. |
| `Sparkle` | **Yes, at ship** | Auto-update for direct distribution. Mature, EdDSA-signed. Non-negotiable for a non-App-Store app that needs to push security fixes. |
| `HotKey` / `MASShortcut` | **Optional** | Thin Carbon wrappers. Vendor the ~150 lines instead; the shortcut recorder UI is the only genuinely fiddly part. |
| Sentry / analytics SDK | **No** | A crash reporter with full memory access in a process that reads all typed text is an unacceptable trade. Ship an opt-in, redacted, self-hosted crash upload instead — or `MetricKit` only. |

## 4. Build & distribution config

```
Deployment target      macOS 14.0   (MenuBarExtra maturity, SMAppService, Observation)
Swift                  6.0, strict concurrency = complete
Sandbox                DISABLED     (required — see 09-risks.md §1)
Hardened Runtime       ENABLED
Notarization           required
Signing                Developer ID Application
Distribution           Direct download (DMG) + Sparkle
```

Strict concurrency on from day one. Retrofitting `Sendable` onto an actor-based orchestrator that touches `AXUIElement` (a `CFType`, not `Sendable`) is significantly worse than paying the cost up front.

## 5. Entitlements

```xml
<key>com.apple.security.app-sandbox</key>          <false/>
<key>com.apple.security.cs.allow-jit</key>         <false/>
<key>com.apple.security.automation.apple-events</key> <true/>
```

The Apple Events entitlement is needed only for `BrowserURLResolver`, which asks Safari/Chrome for the frontmost tab URL to support domain exclusions. If you drop per-domain exclusions from v1, you can drop this entitlement and one TCC prompt with it — a reasonable trade for the first release.
