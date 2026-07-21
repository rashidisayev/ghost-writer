# Roadmap

## MVP — v0.1, target ~10 weeks

The MVP's job is to prove the hard part: that a rewrite can be triggered, shown, and applied invisibly across the apps people actually type in. Everything that is not that is deferred.

**Scope cut deliberately:** three apps, one provider, no underline overlay, no variants.

| Phase | Weeks | Deliverable |
|---|---|---|
| **0 — Spike** | 1–2 | Prove AX read/write in TextEdit, Safari, and Slack. Build `ax-probe`. **Go/no-go gate:** if Slack text cannot be read reliably, the whole product thesis needs revisiting before another line is written. |
| **1 — Skeleton** | 2–3 | `LSUIElement` app, menu bar item, permission onboarding, login item, Keychain, Settings shell |
| **2 — Sensing** | 3–5 | `FocusTracker`, `TextReader`, `KeystrokeMonitor`, `PolicyEngine`, `ScopeResolver`. No AI yet — log what *would* be sent. This ordering is deliberate: the privacy-critical path gets built and reviewed before anything can actually transmit. |
| **3 — AI** | 5–6 | `ClaudeProvider` with SSE streaming, `PromptBuilder`, three built-in tone profiles, cache |
| **4 — UI** | 6–8 | `SuggestionPanel`, word-level diff rendering, Tab/Esc handling, `TextWriter` with AX + paste + verification |
| **5 — Harden** | 8–10 | Compatibility matrix pass over 20 apps, quirk table, latency harness, notarization, Sparkle, DMG |

**MVP feature set:**
- ✅ Manual hotkey (`⌥Space`) and typing-pause triggers
- ✅ Paragraph-scope rewriting, auto language detection
- ✅ 5 built-in tone profiles + custom profile creation
- ✅ Suggestion card with diff, Tab accept / Esc reject
- ✅ Claude provider, user-supplied API key, model picker
- ✅ App exclusion list, secure-input and credential blocking
- ✅ Menu bar with enable/disable and basic stats
- ❌ Underline overlay, alternatives (`⌘↩`), domain exclusions, per-app tone bindings, local models

**Definition of done:** works reliably in Mail, Notes, Safari, Chrome, Slack, and Notion; survives a full workday without a restart; idle CPU under 0.1%.

## v1.0 — target +6 weeks

- Underline overlay where per-range rects are available
- Alternative rewrites (`⌘↩`, 3 variants)
- Per-app and per-domain tone bindings
- Full 12 built-in tone profiles with live preview in Settings
- Domain exclusions (adds the Apple Events entitlement)
- Remote-updatable app quirk table — this is what makes the product maintainable
- Spend tracking and cap warnings
- Selection-only rewrite

## v1.5

- **Explain mode** — hover a change, get a one-line reason. Turns the tool from a corrector into something people learn from, which is the actual retention mechanism for the non-native-speaker segment.
- Glossary and do-not-change lists per tone profile (brand names, product names, internal jargon)
- Whole-document rewrite with progress UI and per-paragraph accept
- Snippet expansion (a natural adjacency — same injection machinery)
- iCloud sync for tone profiles and settings (never for content)

## v2.0

- **Local Mode** — MLX-backed on-device inference (Llama, Mistral, Gemma, Qwen, DeepSeek distills). Model download manager, quality expectations stated honestly per language at the point of switching.
- **Provider plugins** — OpenAI, Gemini, and self-hosted OpenAI-compatible endpoints via the `RewriteProvider` protocol; third-party providers out-of-process over XPC.
- **Transform plugins** — pre/post hooks for redaction, glossary enforcement, team style guides.
- Team tier: shared tone profiles, MDM configuration profile, forced-policy deployment.

## v2.5+ — candidates, not commitments

- Tone-match learning: derive a profile from a corpus of the user's own past writing
- Reply drafting in Mail and Slack (a different product motion — much larger surface, much larger trust ask)
- iOS keyboard extension (a near-total rewrite; keyboard extensions have a completely different and far more restrictive model)
- Real-time inline ghost-text completion, contingent on local models getting fast enough to make it non-annoying

## Sequencing rationale

Two ordering decisions are load-bearing:

**Sensing before AI (Phase 2 before 3).** Building the full read-and-policy path with a logger instead of a network call means the "what would we have sent?" question is answerable and reviewable before the app is capable of sending anything at all. For a product whose main adoption barrier is trust, that ordering is worth the small awkwardness of a phase that does nothing visible.

**The quirk table before feature breadth (v1.0, not v2).** Target apps update every week or two, and each update can break text reading. Without the ability to ship a compatibility fix independently of an app release, the maintenance burden compounds until the team is doing nothing else. It looks like infrastructure work competing with features; it is actually the thing that determines whether features are shippable in year two.
