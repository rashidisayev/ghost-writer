# Security & Privacy

An app with Accessibility and Input Monitoring permission can read every character its user types. That is the correct mental model for the threat surface, and the design should assume users understand it.

## 1. Data classification

| Data | Where it lives | Lifetime |
|---|---|---|
| Field text (the paragraph) | RAM only | Until the pass completes or is cancelled |
| Rewrite suggestions | RAM only, `NSCache` | LRU eviction; cleared on focus change to an excluded app, on sleep, and on lock |
| Recent suggestions list | RAM only, capped at 20 | Cleared on quit. **Never written to disk.** |
| API key | Keychain | Until user removes it |
| Tone profiles | `UserDefaults` (plist) | Persistent — user-authored, not user content |
| Exclusion lists | `UserDefaults` | Persistent |
| Stats (counters) | `UserDefaults` | Persistent. Integers only, no text. |
| Logs | `OSLog` | Text is `privacy: .private`, redacted in log archives |

**Nothing containing user-typed text is ever written to disk.** Not to a cache file, not to a log, not to a crash dump. This is a stated guarantee, and it constrains real decisions: it is why the cache is `NSCache` and not SQLite, and why the crash reporter is `MetricKit` rather than a third-party SDK with memory-dump capability.

## 2. What leaves the machine

In Cloud Mode, exactly one outbound destination: `api.anthropic.com`. The payload is:

- the current paragraph
- up to 300 characters of surrounding context, marked read-only
- the active tone profile text
- the aggressiveness setting

It does **not** include: the app name, the window title, the URL, the user's identity, the filename, other paragraphs in the field, or anything from other applications. The server has no idea whether the text came from Slack or Mail.

This is worth stating in the UI, because it is a meaningfully stronger position than "we send your document to our servers."

## 3. Redaction and blocking

`PolicyEngine` runs before any read, and `CredentialHeuristics` runs before any send.

**Hard blocks (no read at all):**
```swift
IsSecureEventInputEnabled()                                    // system-wide secure input
element.subrole == kAXSecureTextFieldSubrole                   // password field
exclusions.contains(bundleID)
exclusions.matchesDomain(frontmostTabURL)
```

**Send blocks (read happened, send aborted):**
```
- Shannon entropy > 4.2 over a run of ≥ 20 chars    → likely key or token
- Prefix match: sk-, ghp_, gho_, github_pat_, AKIA, ASIA, xoxb-, xoxp-, ya29.
- PEM markers: -----BEGIN
- JWT shape: three base64url segments joined by dots
- 16+ consecutive digits (card / account numbers)
- Text is > 90% non-word characters
```

Blocked passes increment a visible "protected" counter in stats. Making the protection legible is what makes it credible.

**Secure input is subtle.** Any app can enable system-wide secure input and sometimes fails to disable it (a known long-standing bug across several apps). Ghost Writer must re-check `IsSecureEventInputEnabled()` on every pass, not once at focus, and should surface a menu bar hint when secure input has been stuck on for more than a few minutes — users otherwise report "Ghost Writer stopped working" when the real cause is another app.

## 4. Keychain

```swift
kSecClass                = kSecClassGenericPassword
kSecAttrService          = "com.ghostwriter.app.anthropic"
kSecAttrAccount          = "default"
kSecAttrAccessible       = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
kSecUseDataProtectionKeychain = true
```

`ThisDeviceOnly` prevents iCloud Keychain sync — an API key syncing to other devices is a surprise the user did not ask for. `AfterFirstUnlock` rather than `WhenUnlocked` so the agent works after a reboot-and-login without a second prompt.

Access is gated by the app's code signature via the keychain ACL, so a tampered or re-signed binary cannot read the stored key.

## 5. Network

- TLS 1.3 minimum, enforced via `NSAppTransportSecurity` with no exception domains.
- **Certificate pinning: no.** Pinning to Anthropic's cert chain creates an outage the moment they rotate, and the threat it defends against (a local attacker who has already installed a trusted root) is one where an app with Accessibility permission is compromised regardless. Rely on ATS.
- Explicit `URLSessionConfiguration` with `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`. There is no reason for this app to have a URL cache on disk containing request bodies.
- Timeouts: 8s request, 15s resource. A rewrite that takes longer than 8 seconds has already failed as a product.
- No telemetry endpoint. No analytics. No "phone home on launch."

## 6. Anthropic API posture

Set `anthropic-version: 2023-06-01`. Requests carry `x-api-key` from the Keychain, never embedded in the binary or in any config file.

Two things to communicate honestly in the Privacy tab:

1. Data sent to the Claude API is subject to Anthropic's API data-retention and usage policies, and users on a commercial API plan should read those directly. Ghost Writer should link to them rather than paraphrase.
2. The API key is the user's own. Ghost Writer has no server, no proxy, and no account — the app talks directly to Anthropic. This means Ghost Writer's operators cannot see any user text even in principle, which is a stronger guarantee than a policy promise.

If a future hosted plan introduces a Ghost Writer-operated proxy, that changes this section materially and must be a separate, clearly-labelled mode — not a silent default.

## 7. Code signing & integrity

- Developer ID Application signature, Hardened Runtime enabled, notarized, stapled.
- No `com.apple.security.cs.disable-library-validation`, no `allow-unsigned-executable-memory`, no `allow-jit`. An app with this permission set should not be loading arbitrary code.
- Plugins (v2) are verified with `SecStaticCodeCheckValidity` against a pinned team identifier before load, and run out-of-process over XPC so a compromised plugin does not inherit the host's TCC grants.
- Sparkle updates signed with EdDSA; the appcast served over HTTPS from a host with its own key.

## 8. Local Mode (v2) and the honest framing

Local Mode runs an on-device model via MLX or `llama.cpp`, and nothing leaves the machine. It is the right long-term answer for regulated users.

The framing must stay honest, though: a 4–8B local model in 2026 does not match Claude on multilingual rewriting, particularly for Russian, Turkish, and morphologically rich languages. Shipping Local Mode as "the same but private" would produce a wave of "the rewrites got worse" reports. Ship it as an explicit, clearly-labelled trade — with a quality expectation stated in the UI at the moment of switching, and a per-language note where the gap is largest.

## 9. Compliance notes

- **GDPR** — Ghost Writer is not a data controller for user text in Cloud Mode; the user's own API contract with Anthropic governs. Ghost Writer processes locally and transiently. Document this in the privacy policy rather than claiming more than is true.
- **Enterprise deployment** — MDM-deployable configuration profile for forced exclusions, forced Local Mode, and a locked provider. Enterprises will ask for this within the first month of any traction.
- **App Store** — not viable. See [09-risks.md](09-risks.md) §1.
