# Architecture

## 1. Process model

One process. Not two.

A common instinct is to split into a UI app plus a privileged background daemon. Resist it for v1: the Accessibility API requires the *calling process* to be AX-trusted, an `NSPanel` overlay must be drawn by a process with a connection to the WindowServer, and a `LaunchAgent` daemon has neither by default. Splitting buys you a second TCC prompt, XPC plumbing, and a harder debugging story for no isolation win, since both halves would need the same permissions anyway.

**Quill is a single `LSUIElement` (agent) app** — `LSUIElement = true` in `Info.plist` gives no Dock icon, no menu bar app menu, but full WindowServer access. Registered as a login item via `SMAppService.mainApp.register()`.

Internally it is layered, and the layers are separated by protocols so that a future split (or a Network Extension for local models) is a refactor, not a rewrite.

## 2. Layer diagram

```mermaid
graph TB
    subgraph UI["UI layer — SwiftUI + AppKit"]
        MB[MenuBarExtra]
        SW[Settings window]
        CARD[SuggestionPanel<br/>NSPanel · nonactivating]
        UL[UnderlineOverlay<br/>NSPanel · click-through]
    end

    subgraph CORE["Core — the engine"]
        ORC[SuggestionOrchestrator<br/>actor]
        SCOPE[ScopeResolver<br/>paragraph extraction]
        DIFF[DiffEngine<br/>word-level Myers]
        CACHE[RewriteCache<br/>LRU · in-memory]
        POL[PolicyEngine<br/>exclusions · secure input · redaction]
    end

    subgraph SENSE["Sensing — AppKit/AX"]
        FOCUS[FocusTracker<br/>AXObserver]
        READER[TextReader<br/>AXUIElement]
        KEY[KeystrokeMonitor<br/>CGEventTap · passive]
        HOT[HotkeyManager<br/>Carbon RegisterEventHotKey]
        WRITER[TextWriter<br/>AX set / paste]
    end

    subgraph AI["AI abstraction"]
        PROV[[RewriteProvider protocol]]
        CLAUDE[ClaudeProvider<br/>SSE streaming]
        OPENAI[OpenAIProvider<br/>future]
        LOCAL[LocalProvider<br/>future · MLX/llama.cpp]
    end

    subgraph DATA["Persistence"]
        PREFS[SettingsStore<br/>UserDefaults]
        KC[KeychainStore<br/>API keys]
        PLUG[PluginHost<br/>future]
    end

    KEY --> ORC
    HOT --> ORC
    FOCUS --> ORC
    ORC --> POL
    POL --> READER
    READER --> SCOPE
    SCOPE --> CACHE
    CACHE -->|miss| PROV
    PROV --> CLAUDE
    PROV -.-> OPENAI
    PROV -.-> LOCAL
    CLAUDE --> DIFF
    DIFF --> CARD
    DIFF --> UL
    CARD -->|accept| WRITER
    MB --> PREFS
    SW --> PREFS
    SW --> KC
    CLAUDE --> KC
    PREFS --> POL
    PLUG -.-> PROV
```

Solid arrows are v1. Dashed are the extension seams.

## 3. Component breakdown

### 3.1 Sensing

| Component | Responsibility | Key APIs |
|---|---|---|
| `FocusTracker` | Emits `FocusContext` (pid, bundleID, AXUIElement, role, subrole, URL for browsers) whenever the focused element changes | `AXObserver` on `kAXFocusedUIElementChangedNotification`, `NSWorkspace.didActivateApplicationNotification` |
| `TextReader` | Reads value, selected range, caret rect, per-range rects | `AXUIElementCopyAttributeValue`, `kAXBoundsForRangeParameterizedAttribute` |
| `KeystrokeMonitor` | Debounce signal only. **Listen-only tap** — never modifies or consumes events, records no key codes, only a timestamp and a "text-ish keystroke" boolean | `CGEvent.tapCreate(.listenOnly)` |
| `HotkeyManager` | Global shortcuts that work when Quill is not frontmost | Carbon `RegisterEventHotKey` (still the only reliable global hotkey API) |
| `TextWriter` | Applies an accepted rewrite | AX set, or pasteboard + synthetic `⌘V` via `CGEvent` |

`KeystrokeMonitor` is the one piece that alarms security-conscious users, so its contract is narrow by design: it maps every event to `(timestamp, isTextInput: Bool)` and drops the event object immediately. Text content always comes from the Accessibility API, never from the tap.

### 3.2 Core

**`SuggestionOrchestrator`** is a Swift `actor` and owns all mutable session state: current focus, last-read text, in-flight task, debounce timer, pending suggestion. Everything else is stateless or a value type. This makes the concurrency story trivially auditable — there is exactly one place that can race.

State machine:

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Watching: focus gains editable element
    Watching --> Idle: focus lost / app excluded
    Watching --> Debouncing: keystroke
    Debouncing --> Debouncing: keystroke (timer resets)
    Debouncing --> Reading: pause elapsed / sentence end / hotkey
    Reading --> Watching: no meaningful change, or policy block
    Reading --> Inferring: cache miss
    Reading --> Presenting: cache hit
    Inferring --> Presenting: stream complete
    Inferring --> Watching: cancelled (user typed) / error
    Presenting --> Applying: Tab
    Presenting --> Watching: Esc / focus change / user typed
    Presenting --> Inferring: Cmd+Enter (variants)
    Applying --> Watching: verified written
```

The critical edge is `Inferring --> Watching` on any keystroke. A suggestion for text the user has since changed is worse than no suggestion, so the in-flight `Task` is cancelled the moment a new keystroke arrives.

**`ScopeResolver`** extracts the paragraph containing the caret plus up to 300 characters of surrounding context (sent as read-only context, explicitly marked "do not rewrite"). This is what keeps request size — and therefore latency and cost — bounded regardless of document length.

**`PolicyEngine`** is a pure function `(FocusContext, String) -> Decision`. Pure means testable, and it means the "did we leak?" question has one answer site.

**`RewriteCache`** keys on `SHA256(normalizedText ‖ toneProfileID ‖ aggressiveness ‖ modelID ‖ promptVersion)`. In-memory `NSCache`, 200 entries, never written to disk. Hit rate in practice is high because users re-trigger on the same paragraph repeatedly while editing around it.

### 3.3 AI abstraction

```swift
protocol RewriteProvider: Sendable {
    var identifier: String { get }
    var capabilities: ProviderCapabilities { get }
    func rewrite(_ request: RewriteRequest) -> AsyncThrowingStream<RewriteEvent, Error>
    func healthCheck() async throws
}

enum RewriteEvent: Sendable {
    case delta(String)          // incremental text
    case variant(index: Int)    // boundary between alternatives
    case usage(TokenUsage)
    case done
}
```

Streaming is modelled as the primitive even though the suggestion card only renders on completion in v1. Reason: for the "Bold" aggressiveness level and for whole-document rewrites the output is long enough that streaming meaningfully improves perceived latency, and retrofitting streaming into a non-streaming interface is painful. See [10-code-snippets.md](10-code-snippets.md) for the SSE implementation.

`ProviderCapabilities` declares `supportsStreaming`, `supportsVariants`, `maxInputTokens`, `requiresNetwork`, `costPerMTokIn/Out`. The orchestrator reads capabilities rather than switching on provider type, so `LocalProvider` (no cost, no network, smaller context) drops in without touching core logic.

## 4. Data flow — the hot path

```mermaid
sequenceDiagram
    autonumber
    participant U as User
    participant K as KeystrokeMonitor
    participant O as Orchestrator (actor)
    participant P as PolicyEngine
    participant R as TextReader (AX)
    participant C as RewriteCache
    participant A as ClaudeProvider
    participant V as SuggestionPanel
    participant W as TextWriter

    U->>K: types
    K->>O: keystrokeTick(ts)
    Note over O: cancel in-flight task<br/>reset 700ms timer
    O-->>O: timer fires
    O->>P: evaluate(focus)
    alt blocked (secure input / excluded app)
        P-->>O: .block(reason)
        Note over O: return to Watching, no I/O
    else allowed
        P-->>O: .allow
        O->>R: readValue + selectedRange + caretRect
        R-->>O: (text, range, rect)
        O->>O: ScopeResolver → paragraph + context
        O->>C: lookup(hash)
        alt cache hit
            C-->>O: cached rewrite
        else miss
            O->>A: rewrite(request)
            A-->>O: stream deltas → assembled text
        end
        O->>O: DiffEngine.wordDiff(original, rewritten)
        alt diff is empty or trivial
            Note over O: suppress — no card shown
        else meaningful
            O->>V: present(diff, caretRect)
            U->>V: Tab
            V->>W: apply(rewrite, strategy)
            W->>R: re-read to verify
            W-->>O: .applied / .failed
        end
    end
```

Steps 5–7 (policy → read) run in under a millisecond. Step 12 is the only unbounded one, and it is the only one that can be cancelled.

## 5. Data flow — replacement strategy selection

```mermaid
flowchart TD
    A[Accept pressed] --> B{Element supports<br/>kAXValueAttribute write?}
    B -->|No| P[Paste strategy]
    B -->|Yes| C{App class}
    C -->|Native Cocoa| D[AX set on selected range]
    C -->|Browser / Electron| P
    C -->|Unknown| P
    D --> E[Re-read field]
    P --> F[Save pasteboard →<br/>set → synth ⌘V →<br/>restore after 250ms]
    F --> E
    E --> G{Text matches<br/>expected?}
    G -->|Yes| H[Restore caret offset<br/>Record accept in stats]
    G -->|No, and AX was used| P
    G -->|No, and paste was used| I[Abort · restore pasteboard ·<br/>surface one-time notice]
```

The AX-then-paste fallback matters: `kAXValueAttribute` writes report success and do nothing in a large fraction of web content. Verifying by re-read is the only reliable signal.

## 6. Threading model

| Work | Executor |
|---|---|
| `CGEventTap` callback | Dedicated `CFRunLoop` on a high-priority thread. Does one atomic timestamp store and returns. |
| `AXObserver` callbacks | Main run loop (required by the API) |
| AX reads/writes | Main actor — AX is not thread-safe and cross-thread use produces intermittent `kAXErrorCannotComplete` |
| Orchestration, diffing, caching | `SuggestionOrchestrator` actor, background executor |
| Network | `URLSession` async, structured-concurrency child tasks of the orchestrator's task |
| UI | `@MainActor` |

AX calls on the main actor is a real constraint: a slow `AXUIElementCopyAttributeValue` against a hung app will block the main thread. Mitigation is `AXUIElementSetMessagingTimeout(element, 0.25)` on every element Quill touches, plus never reading in a loop.

## 7. Plugin architecture (v2 seam)

Two extension points, both defined in v1 so the shapes don't have to change later:

1. **Providers** — anything conforming to `RewriteProvider`. In-process for built-ins; out-of-process via XPC for third-party, so a crashing plugin cannot take down the agent.
2. **Transforms** — `(RewriteRequest) -> RewriteRequest` and `(RewriteResult) -> RewriteResult` hooks, registered in an ordered chain. This is how "redact company names before sending", "enforce a glossary", or "append a team style guide" get built without forking.

Distribution as signed bundles in `~/Library/Application Support/Quill/Plugins`, validated by code signature before load.
