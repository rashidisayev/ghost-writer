# Risks & Limitations

Ordered by how likely they are to kill the project.

## 1. App Store distribution is not possible — plan around it

**This is a structural constraint, not a hurdle.**

The Mac App Store requires the App Sandbox. The Accessibility API's cross-process element access (`AXUIElementCreateApplication`, reading `kAXValueAttribute` from another process) is not permitted from a sandboxed app — there is no entitlement that grants it. `CGEventTap` is likewise unavailable. This is why Grammarly, TextExpander, Alfred, Raycast, Keyboard Maestro, and every comparable tool ship outside the App Store or ship a crippled App Store build alongside a full direct download.

**Consequences to plan for from day one:**
- Developer ID + notarization + stapling; Sparkle for updates; DMG with a signed background image
- Own the payment stack (Paddle, Lemon Squeezy, or Stripe) and the licence-key system
- No App Store discovery — distribution is entirely earned through content, word of mouth, and search
- Gatekeeper first-run friction: the "unidentified developer" path if notarization ever fails is a conversion killer, so notarization must be in CI and its failure must break the build

There is no workaround. Design the business around direct distribution rather than treating it as a fallback.

## 2. Permission friction is the top funnel loss

Two TCC prompts before the app does anything useful, one of which ("Input Monitoring") reads to a wary user as "this app wants to log my keystrokes." Realistic expectation: a meaningful fraction of installs never complete onboarding.

**Mitigations:**
- Make Input Monitoring genuinely optional with a fully functional manual-hotkey mode. Not a degraded mode — a real one.
- Explain the timestamp-only contract at the point of asking, in the app, in plain language.
- Demonstrate value before asking: onboarding screen 1 shows a rewrite happening in a mock UI, so the user knows what they are trading for.
- Deep-link directly to the correct System Settings pane and poll for the grant so the flow completes without the user having to find their way back.

## 3. Accessibility APIs break with target-app updates

Chromium, Electron, and WebKit change their accessibility tree implementations regularly, and `AXManualAccessibility` / `AXEnhancedUserInterface` are private, undocumented attributes. A Slack or Chrome update can silently break text reading for a large slice of users on a Tuesday.

**Mitigations:** the remote-updatable quirk table (see [05](05-accessibility-strategy.md) §8) so fixes ship in hours; an automated daily compatibility smoke test against the top apps; an in-app "report a broken app" action that attaches an `ax-probe` dump with text redacted.

**Residual risk stays high.** This is the permanent tax of the category and it should be staffed for, not hoped away.

## 4. Text corruption is the trust-ending failure

Replacement can go wrong: a stale range after the user typed during the request, a paste landing in the wrong field after a focus change, an app that handles `⌘V` unusually. A single incident of Ghost Writer mangling someone's email is worth more negative word of mouth than fifty good rewrites are worth positive.

**Mitigations:** cancel on any keystroke; re-verify focus identity and text hash immediately before writing; verify by re-read after writing and abort on mismatch; never write to a field that changed since the read; keep the rewrite in the pasteboard history marker so a failed apply is recoverable by the user.

## 5. Latency and cost economics

At Opus 4.8 pricing ($5/$25 per MTok), a 60-word paragraph rewrite is roughly 300 input + 200 output tokens ≈ $0.006. A heavy user triggering 200 rewrites a day costs ~$1.20/day — about $36/month, well above any plausible subscription price.

This means **bring-your-own-key is the correct v1 model**, not a stopgap. It aligns cost with usage, removes the operator from the data path entirely (a genuine privacy advantage, see [06](06-security-privacy.md) §6), and sidesteps the unit-economics trap that has caught several AI writing tools.

If a managed plan is ever offered, it needs Haiku-by-default, aggressive caching, hard per-user rate limits, and pricing built from measured p95 usage — not from an average.

## 6. Rewrite quality regressions users can't diagnose

Prompts that work well in English can produce over-formal Russian, unnaturally clipped German, or subtly wrong Turkish agglutination. Users experience this as "the app is bad at my language" and churn without reporting it.

**Mitigations:** a per-language regression corpus (≥50 paragraphs each for EN, DE, RU, ES, FR, TR, PT, IT) reviewed by native speakers before any prompt change ships; `promptVersion` in the cache key so changes are cleanly A/B-able; a thumbs-down affordance on the card that records only the language, tone, and model — never the text.

## 7. Secure input false negatives

If another app leaves system-wide secure input enabled (a recurring bug across several popular apps), Ghost Writer goes dormant and users report it as broken. Conversely, a custom-drawn password field that does not set the secure subrole and does not enable secure input would not be detected as sensitive.

**Mitigations:** for the first case, detect a stuck secure-input state and surface an explanatory menu bar hint naming the likely culprit process. For the second, the credential heuristics in [06](06-security-privacy.md) §3 are the backstop — which is precisely why the send-block layer exists in addition to the read-block layer.

## 8. Competitive and platform risk

Grammarly has enormous distribution and is shipping AI features. Apple ships Writing Tools system-wide in recent macOS, free, with on-device privacy — and Apple can deepen that at any WWDC.

The defensible position is not "AI rewriting," which is commoditizing fast. It is the combination of **user-authored tone profiles**, **true multilingual parity**, **per-app behaviour**, and **bring-your-own-key privacy**. Apple's Writing Tools will not ship per-app custom prompt profiles, and Grammarly's multilingual support is not close to parity. That is the wedge; the product should be built and marketed around it rather than around raw rewrite quality.

## 9. Smaller known limitations

| Limitation | Status |
|---|---|
| Canvas-based editors (Figma text, Google Docs' canvas renderer) expose no usable AX text | Unsupported. Detect and go dormant. |
| Java, Qt, SDL, and most game UIs have no AX tree | Unsupported. |
| Undo behaviour after an AX write varies by app | Prefer paste strategy where undo fidelity matters |
| Pasteboard managers may capture transient rewrites | Transient/concealed markers help with well-behaved ones; not all honour them |
| Rich text loses formatting on paste replacement | v1 handles plain text only; rich-text preservation is a v1.5 problem |
| RTL languages (Arabic, Hebrew) need overlay geometry work | Rewriting works; underline positioning does not. Ship with the caret indicator fallback. |
| Multi-display and mixed-scale setups complicate rect conversion | Convert against the primary screen's frame; test explicitly on mixed-DPI setups |
| Very long paragraphs (>2000 chars) blow the latency budget | Split at sentence boundaries or ask the user to select a range |
