# Accessibility API Integration Strategy

This is where the product lives or dies. Everything else is a normal Mac app; this part is the hard problem, and it is largely a compatibility-engineering problem rather than a design one.

## 1. Permission model

Two separate TCC permissions, granted independently, each with its own failure mode.

| Permission | Needed for | If denied |
|---|---|---|
| **Accessibility** | Reading and writing text, focus tracking | Product is non-functional. Hard requirement. |
| **Input Monitoring** | `CGEventTap` typing-pause detection | Automatic triggering unavailable. **Manual hotkey mode still works fully.** |

Checking and prompting:

```swift
// Check without prompting — safe to call on every launch and periodically.
let trusted = AXIsProcessTrusted()

// Prompt once, on user action during onboarding. Never at launch.
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
_ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
```

Three things that bite:

1. **The trust state is cached per code signature.** Rebuild with a different signature during development and macOS treats it as a new app while often keeping the stale entry — the checkbox looks enabled and the API returns `false`. Fix: `tccutil reset Accessibility <bundle-id>` in a dev script, and instruct users to toggle the checkbox off/on after an update if permissions appear broken.
2. **Permission can be revoked while running.** Poll `AXIsProcessTrusted()` every 30s (it is cheap) and degrade to a clear "permission lost" menu bar state rather than silently doing nothing.
3. **Input Monitoring has no reliable pre-flight check.** `CGPreflightListenEventAccess()` exists but is unreliable across versions. Treat "tap created but never fires" as the real signal: if no events arrive within 5s of creation while the user is typing, show the grant prompt.

## 2. Focus tracking

```swift
// One system-wide observer for app switches, plus one AXObserver per
// observed application (observers are pid-scoped).
let system = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(system, 0.25)

var focused: CFTypeRef?
AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
```

Per-app `AXObserver` registered for:
- `kAXFocusedUIElementChangedNotification` — caret moved to a different control
- `kAXValueChangedNotification` — text changed (useful in apps where the event tap is unavailable)
- `kAXUIElementDestroyedNotification` — clean up the observer

Observers must be added to the main run loop, and every observer must be torn down when its app quits or the process leaks Mach ports steadily.

## 3. Reading text

```swift
kAXValueAttribute                          // full text
kAXSelectedTextAttribute                   // current selection
kAXSelectedTextRangeAttribute              // CFRange as AXValue
kAXNumberOfCharactersAttribute             // length, cheap
kAXBoundsForRangeParameterizedAttribute    // CGRect for a CFRange — for the overlay
kAXStringForRangeParameterizedAttribute    // read a substring without pulling the whole field
```

`kAXStringForRangeParameterizedAttribute` is the one to reach for on large fields. Pulling `kAXValueAttribute` from a 200KB editor buffer on every pass is the difference between a snappy app and a laggy one.

## 4. The app compatibility matrix

This is the real spec. Every one of these behaviours is a separate code path.

| Surface | AX text readable | Per-range rects | Write via AX | Recommended strategy |
|---|---|---|---|---|
| Native Cocoa (`NSTextView`, `NSTextField`) — Mail, Notes, TextEdit, Xcode | ✅ | ✅ | ✅ | AX read + AX write. Full underline overlay. |
| Safari (WebKit) | ✅ | ⚠️ partial | ⚠️ unreliable | AX read + paste write. Caret indicator only. |
| Chrome / Arc / Edge (Chromium) | ⚠️ needs opt-in | ⚠️ partial | ❌ | See §5. AX read + paste write. |
| Firefox | ⚠️ needs opt-in | ❌ | ❌ | AX read + paste write. |
| Electron — Slack, Discord, Teams, VS Code, Cursor, Notion | ⚠️ needs opt-in | ❌ | ❌ | See §5. AX read + paste write. |
| iMessage / Messages | ✅ | ✅ | ⚠️ | AX read + paste write. |
| WhatsApp / Telegram (Electron/Catalyst) | ⚠️ mixed | ❌ | ❌ | AX read + paste write. Test per version. |
| Outlook (new, WebView2-based) | ⚠️ needs opt-in | ❌ | ❌ | Paste write. |
| Terminal / iTerm | ✅ but meaningless | — | ❌ | **Excluded by default.** Shell input is not prose. |
| Password fields | — | — | — | **Hard blocked.** |
| Java / Qt / SDL / game engines | ❌ | ❌ | ❌ | Unsupported. Detect and go dormant. |

## 5. Forcing accessibility on in Chromium, Electron, and Firefox

These apps ship with their accessibility tree **off** for performance and build it lazily when an assistive client asks. Ghost Writer must ask, explicitly, per application:

```swift
// Electron apps (Slack, Discord, VS Code, Notion, Teams…)
let app = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

// Chromium and Firefox
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
```

Both are private, undocumented attributes. They are also how every assistive technology on macOS works with these apps, so they are stable in practice — but treat them as a compatibility layer, not an API:

- **Cost.** Enabling the tree makes the host app do real work on every DOM mutation. In a heavy Notion page or a large VS Code file this is measurable. Ghost Writer therefore enables it **lazily, per app, on first editable focus**, and disables it when the app has had no editable focus for 5 minutes.
- **Side effects.** `AXEnhancedUserInterface` on Chromium historically caused window-resize glitches and is known to interact badly with some window managers. Ship a per-app override so a user hitting this can turn Ghost Writer off for that app rather than uninstalling.
- **Failure is expected.** If the attribute set fails or the tree is still empty 500ms later, mark the surface unsupported and go dormant. Never retry in a loop.

## 6. Writing text

### Strategy A — AX write (native apps)

```swift
// Ranged replace — preferred, keeps surrounding text untouched
AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString)
```

Fast, no pasteboard involvement, no synthetic events. Downsides: undo support varies by app (`NSTextView` generally coalesces it into one undoable edit; many custom views do not register it at all), and it silently no-ops in web content.

### Strategy B — synthetic paste (everything else)

```
1. Snapshot NSPasteboard contents (all types, all items)
2. Select the target range (AX set on kAXSelectedTextRangeAttribute)
3. Write replacement to the pasteboard
4. Post ⌘V via CGEvent to the target pid
5. Wait ~250 ms, restore the original pasteboard
```

This is the strategy Grammarly, TextExpander, and every mature text-injection tool converges on, because it is the only one that works everywhere and **preserves the host app's native undo stack** — the app sees an ordinary paste, so `⌘Z` does exactly what the user expects.

Its known costs, and the mitigations:

| Cost | Mitigation |
|---|---|
| Pasteboard managers (Paste, Raycast, Maccy) capture the transient content | Set `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType` markers, which well-behaved managers honour |
| Restore races if the user copies during the 250ms window | Compare `changeCount` before restoring; if it changed, don't restore |
| Requires the app to be frontmost | Always true by construction — the user is typing in it |
| Fails silently if the app ignores `⌘V` | Verify by re-reading the field; abort and notify on mismatch |

### Verification

Always re-read after writing and compare against the expected result. Both strategies fail silently in the wild; verification is what converts a silent corruption bug into a graceful abort.

## 7. Caret and geometry

```swift
var range = CFRange(location: caretOffset, length: 1)
let rangeValue = AXValueCreate(.cfRange, &range)!
var boundsRef: CFTypeRef?
AXUIElementCopyParameterizedAttributeValue(
    element,
    kAXBoundsForRangeParameterizedAttribute as CFString,
    rangeValue, &boundsRef
)
var rect = CGRect.zero
AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect)
```

Returned rects are in **screen coordinates with a top-left origin** (Core Graphics convention), while `NSWindow` positioning uses bottom-left. Convert against `NSScreen.screens[0].frame.maxY`, not the current screen — a classic source of "the card appears on the wrong monitor" bugs.

When this attribute is unsupported, fall back in order: element frame from `kAXPositionAttribute` + `kAXSizeAttribute` → position the card at the element's bottom edge → position at the mouse location. Never guess a character-level position.

## 8. Per-app quirk table

Compatibility knowledge belongs in data, not in `if` statements scattered through the reader. `AXCompat.swift` holds a table keyed by bundle ID:

```swift
struct AppQuirks {
    var needsManualAccessibility: Bool   // Electron
    var needsEnhancedUI: Bool            // Chromium, Firefox
    var writeStrategy: WriteStrategy     // .axSet | .paste | .unsupported
    var supportsRangeBounds: Bool
    var readStrategy: ReadStrategy       // .fullValue | .rangedSubstring
    var excludedByDefault: Bool
    var pasteSettleMS: Int               // some Electron apps need 400ms
}
```

Ship with a curated table for the top ~40 apps, fall back to conservative defaults (paste strategy, no range bounds) for unknown apps, and — importantly — **ship the table as a signed remote-updatable JSON** so a Slack update that breaks text reading can be fixed in hours rather than in the next app release. This is the single highest-leverage piece of infrastructure in the whole project.

## 9. Test strategy

- **Unit** — `ScopeResolver`, `DiffEngine`, `PolicyEngine`, `SSEParser`. Hermetic, no AX.
- **Integration** — a harness that scripts TextEdit, Safari, and a bundled Electron test app through AX: focus, type, trigger, accept, assert final buffer. Runs in CI on a signed, pre-authorized runner.
- **Compatibility matrix run** — a manual checklist against the top 20 apps, executed each release and after any major target-app update. This cannot be fully automated and pretending otherwise is how these products rot.
- **`ax-probe`** — the CLI tree dumper, used to triage every user compatibility report.
