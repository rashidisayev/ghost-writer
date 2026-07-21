# Quill — Product Specification

> Working name. A system-wide, AI-native writing assistant for macOS, powered by Claude.

## 1. Product summary

Quill is a background macOS agent that observes the text field the user is currently typing in, and offers rewrites that preserve meaning while improving grammar, clarity, structure, and tone — in whatever language the user is writing. It has no Dock icon, no window in the way, and no requirement that the user switch apps. It behaves like a system service.

The differentiator versus Grammarly is not "AI" — Grammarly has AI. The differentiator is **tone profiles as first-class user-authored prompts**, **true multilingual parity** (a Russian email gets Russian-native rewriting, not English rules translated), and **a privacy posture where the user can see and control exactly what leaves the machine**.

## 2. Target users

| Segment | Core need |
|---|---|
| Non-native English professionals | Write confidently in a second language without sounding stilted |
| Engineering managers / ICs | Turn terse Slack thoughts into readable messages; tone-shift for audience |
| Sales / CS / support | Consistent brand voice across hundreds of short messages |
| Multilingual teams | One tool that works in DE, RU, ES, TR, FR without switching |

## 3. Principles

1. **Never block typing.** Every code path on the keystroke thread is O(1) and allocation-free where possible. Inference is always off the main thread and always cancellable.
2. **Suggest, don't replace.** Nothing is ever silently rewritten. Every change is an explicit accept.
3. **Fail invisibly.** Network down, API error, rate limit → the user sees nothing and keeps typing. Errors surface only in the menu bar.
4. **The user owns the prompt.** Tone profiles are editable text. No hidden system prompt the user can't inspect.
5. **Least data.** Send the smallest span that produces a good rewrite. Never send more than the current paragraph unless the user asks.

## 4. Feature specification

### 4.1 Universal text monitoring

**Goal.** Detect the focused editable element in any application and read its current text and caret position.

**Behaviour.**
- On focus change, Quill resolves the focused `AXUIElement` and classifies it: native text field, native text view, web content area, Electron surrogate, terminal, unknown.
- Text is read via `kAXValueAttribute`; selection via `kAXSelectedTextRangeAttribute`; caret rect via the parameterized `kAXBoundsForRangeParameterizedAttribute`.
- If the element does not expose a readable value (common in Terminal, some canvas-based editors, some games), Quill marks the app as **unsupported** for that surface and goes dormant. It does not fall back to keystroke logging.

**Triggers for a rewrite pass:**

| Trigger | Default | Configurable |
|---|---|---|
| Typing pause | 700 ms of no keystrokes, ≥ 25 chars changed since last pass | 300–2000 ms |
| Sentence terminator | `.` `!` `?` `。` `؟` followed by space/newline | on/off |
| Manual hotkey | `⌥Space` | fully rebindable |
| Selection rewrite | User selects text, presses hotkey → rewrite selection only | fully rebindable |

**Hard blocks — Quill never reads text when:**
- `IsSecureEventInputEnabled()` is true (password fields, sudo prompts, 1Password)
- The element has `kAXSubroleAttribute == kAXSecureTextFieldSubrole`
- The frontmost app is in the user's exclusion list
- The focused browser tab's host matches an excluded domain
- The field contains a string matching a credential heuristic (long base64/hex runs, `sk-`/`ghp_`/`AKIA` prefixes, PEM headers) → pass aborted, counted in stats as "redacted"

### 4.2 AI rephrasing

**Scope selection.** Quill rewrites the **current paragraph** by default (text between the nearest blank lines around the caret), not the whole field. This bounds latency, bounds cost, and bounds privacy exposure. Whole-field rewrite is an explicit action (`⌥⇧Space`).

**Language handling.** No language selector in the hot path. The prompt instructs Claude to detect and reply in the source language. A local CLD-style detector (`NLLanguageRecognizer`, on-device, free) runs first only to (a) skip rewriting if confidence is low and text is < 15 chars, and (b) tag the suggestion in the UI. The model, not the detector, is authoritative.

**Quality contract.** The rewrite must:
- preserve semantic content, all named entities, all numbers, all URLs, all code spans
- preserve the author's register unless a tone profile overrides it
- fix grammar, spelling, punctuation, agreement, article/preposition use
- improve clarity, word choice, and sentence structure
- **not** add information, opinions, greetings, or sign-offs the author did not write
- **not** translate

**Aggressiveness levels** (setting):

| Level | Behaviour |
|---|---|
| Light | Correctness only — grammar, spelling, punctuation. Structure untouched. |
| Balanced (default) | Correctness + clarity + word choice. Sentence boundaries may move. |
| Bold | Full rewrite for impact. May restructure paragraphs and cut sentences. |

### 4.3 Tone profiles

A tone profile is `{ name, icon, systemPromptFragment, aggressivenessOverride?, appBindings[] }`.

Built-ins ship as editable presets: Professional, Business, Friendly, Funny, Family, Formal, Casual, Executive, Technical, Sales, Marketing, Customer Support.

Users create profiles from free text — *"Rewrite everything as if I were an experienced engineering manager"*, *"Make everything concise and direct"*, *"Sound like Steve Jobs"*. The text is inserted into the system prompt verbatim inside a delimited block; it cannot override the safety and no-fabrication rules, which sit after it.

**Per-app binding.** A profile can be bound to a bundle ID or a domain. Slack → Friendly. Outlook → Business. `github.com` → Technical. Resolution order: explicit manual override for this session → domain binding → bundle-ID binding → global default.

### 4.4 Suggestions UI

Quill never mutates the field to show a suggestion. It draws an overlay.

- **Underline layer.** A borderless, click-through `NSPanel` at `.floating` level, `canJoinAllSpaces` + `fullScreenAuxiliary`, positioned using per-range rects from `kAXBoundsForRangeParameterizedAttribute`. Changed spans get a subtle underline. When per-range rects are unavailable (most web/Electron content), Quill degrades to a single caret-anchored indicator rather than drawing wrong.
- **Suggestion card.** A non-activating `NSPanel` anchored below the caret rect. Shows the rewritten paragraph with word-level diff highlighting (insertions green, deletions struck red), the active tone profile, and the detected language.
- **Keyboard:** `Tab` accept · `Esc` reject · `⌘↩` request alternatives (3 variants, arrow keys to cycle) · `⌥↩` accept and pin this tone for the current app.

The card is `.nonactivatingPanel` so the user's app never loses key-window focus and the caret keeps blinking.

### 4.5 Replacement

On accept, in order of preference:

1. **AX set** — write `kAXValueAttribute` (or `kAXSelectedTextAttribute` for a ranged replace). Fast, no pasteboard involvement. Breaks undo in many apps and silently fails in most web content.
2. **Synthetic paste** — save the pasteboard, set the rewrite, post `⌘V`, restore the pasteboard after a delay. Universal, preserves the app's native undo stack. This is the default for browsers and Electron.
3. **Bail** — if neither is verified to have applied (Quill re-reads the field and compares), the suggestion is dropped and the user is told once.

Cursor position is restored to `originalCaretOffset + (newLength - oldLength)` when the caret was at or after the rewritten span, or left in place when before it.

### 4.6 Menu bar & settings

Menu bar item: enable/disable toggle · pause for 30 min · current tone profile picker · recent suggestions (last 20, in-memory only) · stats · Settings · Quit.

Settings window (SwiftUI, `Settings` scene): General · Triggers & Shortcuts · Tone Profiles · Languages · Exclusions · AI Provider · Privacy · About.

Stats are local-only counters: passes run, suggestions shown, accept rate, top languages, estimated tokens, estimated spend. No content is retained.

## 5. Non-goals for v1

- Real-time inline "as-you-type" ghost text (latency and cost do not support it at quality)
- Document-level restructuring or long-form editing
- Team/shared style guides and admin policy (v2)
- Windows or iOS
- Translation
