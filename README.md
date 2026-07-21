# Ghost Writer

A background macOS agent that rewrites your prose in **any** editable text field, in **any** application — Slack, Mail, a browser, a native app — without changing how you work. Put the caret in a paragraph, press <kbd>⌥⌘K</kbd> or click the button that appears beside the field, and a suggestion card offers a cleaner version.

No Dock icon, no window to switch to, no copy-paste round trip.

> **Status: working prototype, not shipped.** It builds, runs, holds Accessibility permission, follows focus across apps, and reads text out of real applications. The parts that are verified and the parts that aren't are listed honestly under [Status](#status) — read that before trusting it with anything.

---

## How it works

```
focused text field  →  read via Accessibility API  →  scope to the paragraph
                                                            ↓
   apply to the field  ←  suggestion card  ←  stream from the OpenAI Responses API
```

Four decisions shape everything else:

**1. One non-sandboxed agent process.** The Accessibility API only answers an AX-trusted process, and the overlay needs a WindowServer connection. Splitting into app + daemon would buy two TCC prompts and XPC plumbing for no isolation benefit. The cost is real and permanent: **the Mac App Store is off the table.** Distribution is Developer ID + notarization only.

**2. Paragraph scope, not document scope.** Rewriting only the paragraph around the caret is what makes the latency budget, the cost model, and the privacy story work simultaneously. One decision, three problems solved.

**3. Bring your own API key.** The key lives in your Keychain and the app talks straight to `api.openai.com`. There is no Ghost Writer server, so the author cannot see your text *even in principle* — a materially stronger claim than a privacy policy.

**4. Policy runs before any read.** Secure fields, password managers, terminals and excluded apps are rejected on the *descriptor* — role and bundle ID — before a single character is read. A send-side credential scan then blocks anything key-shaped from leaving the machine even if it was read legitimately.

---

## Requirements

| | |
|---|---|
| macOS | 14.0+ |
| Swift | 6.0+ (Xcode 16 / Swift 6.3 toolchain) |
| API | An [OpenAI API key](https://platform.openai.com/api-keys) **with credit on the account** |

A ChatGPT Plus or Pro subscription does **not** include API access. They are separate products with separate billing — an account without a prepaid API balance returns `429 insufficient_quota` on the very first request.

---

## Build and run

```bash
git clone https://github.com/rashidisayev/ghost-writer.git
cd ghost-writer
./Scripts/build-app.sh release
open build/GhostWriter.app
```

`Scripts/build-app.sh` compiles the SPM package and assembles a real `.app` bundle around the executable. That wrapping is not optional: `MenuBarExtra` and `LSUIElement` need genuine bundle identity, and a bare executable gets a Dock icon and no menu bar item.

Then:

1. Click the menu bar icon → **Grant Accessibility permission…**, and enable Ghost Writer in System Settings.
2. Open **Settings…** and paste your OpenAI API key (**Save & Verify** sends one minimal request to confirm it).
3. Put the caret in a paragraph anywhere and press <kbd>⌥⌘K</kbd>.

### Running the tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The `DEVELOPER_DIR` prefix is required if `xcode-select` points at the Command Line Tools, which don't ship XCTest. Plain `swift build` and the bundle script work fine without it.

### The Accessibility grant dies on every rebuild

TCC keys an Accessibility grant to the **code directory hash**, and ad-hoc signing produces a new hash on every build. The old entry stays visible and switched on in System Settings while applying to a binary that no longer exists — so it reads as *granted* and behaves as *denied*.

After each rebuild:

```bash
tccutil reset Accessibility com.ghostwriter.app
```

then re-grant from the menu. A real Developer ID certificate gives a stable signature and makes this go away.

---

## Project layout

```
Sources/
  GhostWriterCore/           Pure logic, no I/O — models, policy, diff, scope resolution
  GhostWriterAccessibility/  All AX interaction: read, write, focus tracking, quirks
  GhostWriterAI/             OpenAI Responses API client and prompt construction
  GhostWriterStorage/        Keychain and UserDefaults
  GhostWriterInput/          Global hotkey
  GhostWriterUI/             Suggestion panel, field overlay, settings, coordinator
  GhostWriter/               App entry point, menu bar
Tools/ax-probe/        Standalone CLI for testing AX support app-by-app
Scripts/               Bundle assembly, icon generation
docs/                  Design documents (01–10) and the compatibility matrix
```

`GhostWriterCore` has no dependencies and holds everything testable without a UI or a network — which is why the test suite covers policy, scoping and Unicode handling but not the panels.

---

## The part that will break: accessibility

The real risk is not the AI and not the UI. It is the Accessibility layer.

Chromium, Electron and WebKit change their accessibility trees regularly, and the attributes that turn those trees on — `AXManualAccessibility`, `AXEnhancedUserInterface` — are **private and undocumented**. A Slack update can break text reading on a Tuesday.

Three mitigations are in the code today:

- **Speculative priming.** Every app is primed on activation, including ones absent from the quirk table. Priming only apps in a hardcoded list means every Electron app nobody thought to add silently reads as "no text field focused".
- **Per-process focus resolution.** Focus is read from the target process directly, never from the system-wide element — the system-wide element resolves against whatever is frontmost, and clicking Ghost Writer's own menu makes *Ghost Writer* frontmost.
- **Paste-first writing.** AX writes report success and silently no-op in most web content. Pasting works everywhere and preserves the host app's undo stack.

The architectural fix — a remote-updatable, signed quirk table so compatibility fixes ship in hours ([docs/05](docs/05-accessibility-strategy.md) §8) — is designed but **not built**. It reads like infrastructure competing with features; it is what decides whether features stay shippable in year two.

Per-app results belong in [docs/compatibility-matrix.md](docs/compatibility-matrix.md). Fill it in with:

```bash
cd Tools/ax-probe && swiftc -O main.swift -o ax-probe
./ax-probe --delay 5 --write
```

---

## Privacy

- The API key is stored in the **Keychain**, never in `UserDefaults` or a file, and never syncs to iCloud (`kSecAttrSynchronizable` is never set).
- Text goes to `api.openai.com` and nowhere else. Requests are sent with `store: false`.
- The URL session is ephemeral with caching and cookies disabled, so request bodies are never written to disk.
- Secure fields are never read. Password managers, terminals and any app on your exclusion list are rejected before the read.
- A credential scan blocks API keys, tokens, private keys and card-shaped digit runs from being sent, biased hard toward false positives — a skipped rewrite costs nothing, a leaked key is unrecoverable.

---

## Status

**Verified working**, by direct test rather than assumption:

- Builds clean; 25 unit tests pass
- Launches as a menu bar agent with no Dock icon, correct bundle identity, ad-hoc signed
- Accessibility permission detection updates live (~2s) without a relaunch
- Reads text from a real app while that app is **not** frontmost — the case that matters, since triggering from the menu makes Ghost Writer frontmost
- Field overlay geometry lands correctly on the focused field
- Keychain read/write/delete round-trips on an ad-hoc signature

**Not yet verified:**

- **No successful API call has been made.** The request shape against `/v1/responses` is written from current OpenAI docs but has never returned 200, because the account under test had no credit. The first live rewrite is where a wrong field name would surface.
- **Slack, Chrome and Safari are untested.** TextEdit — a native `NSTextView` — is the only confirmed app. The browsers and Electron are the go/no-go set described in [BUILD.md](BUILD.md) step 2, and they decide whether this product is viable at all.
- **Writing back has not been exercised end to end.**
- Multi-monitor overlay placement is measured against the primary screen and will be wrong on a second display.

See [BUILD.md](BUILD.md) for the execution runbook, sequenced so every uncertain thing happens before every tedious thing.

---

## Design documents

| # | Document | Contents |
|---|---|---|
| 01 | [Product Specification](docs/01-product-spec.md) | Vision, principles, feature spec, non-goals |
| 02 | [Architecture](docs/02-architecture.md) | Process model, layers, components, state machine |
| 03 | [UI Wireframes](docs/03-ui-wireframes.md) | Suggestion card, overlay, menu bar, settings |
| 04 | [Project Structure](docs/04-project-structure.md) | SPM layout, dependency decisions, build config |
| 05 | [Accessibility Strategy](docs/05-accessibility-strategy.md) | Permissions, focus tracking, write strategies |
| 06 | [Security & Privacy](docs/06-security-privacy.md) | Data classification, redaction, Keychain, network |
| 07 | [Performance](docs/07-performance.md) | Budgets, debouncing, caching, latency levers |
| 08 | [Roadmap](docs/08-roadmap.md) | MVP phases, v1.0 → v2.0, sequencing rationale |
| 09 | [Risks & Limitations](docs/09-risks.md) | App Store, permission friction, AX fragility |
| 10 | [Code Snippets](docs/10-code-snippets.md) | Reference Swift for the hardest components |

---

## License

None yet. All rights reserved until one is chosen.
