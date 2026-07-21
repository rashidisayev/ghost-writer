# App Compatibility Matrix

Fill this in by running `Tools/ax-probe/ax-probe --delay 5 --write` against each app.
This is empirical data, not design — record what you actually observe, including the surprises.

**Legend:** ✅ works · ⚠️ partial · ❌ unavailable · `—` not yet tested

## Tier 1 — the go/no-go set

Test these first. See [BUILD.md](../BUILD.md) step 2 for the gate.

| App | Bundle ID | Read text | Caret range | Range bounds | AX write applies | Needs activation | Verdict |
|---|---|---|---|---|---|---|---|
| Slack | `com.tinyspeck.slackmacgap` | — | — | — | — | — | — |
| Chrome | `com.google.Chrome` | — | — | — | — | — | — |
| Arc | `company.thebrowser.Browser` | — | — | — | — | — | — |
| Safari | `com.apple.Safari` | — | — | — | — | — | — |

## Tier 2 — native baseline

Expected to work. If these fail, something is wrong with the environment, not the app.

| App | Bundle ID | Read text | Caret range | Range bounds | AX write applies | Needs activation | Verdict |
|---|---|---|---|---|---|---|---|
| TextEdit | `com.apple.TextEdit` | ✅ | ✅ | — | — | ❌ no | ✅ reads as `AXTextArea`, value settable, range available with another app frontmost |
| Mail | `com.apple.mail` | — | — | — | — | — | — |
| Notes | `com.apple.Notes` | — | — | — | — | — | — |
| Messages | `com.apple.MobileSMS` | — | — | — | — | — | — |

## Tier 3 — the long tail

| App | Bundle ID | Read text | Caret range | Range bounds | AX write applies | Needs activation | Verdict |
|---|---|---|---|---|---|---|---|
| Discord | `com.hnc.Discord` | — | — | — | — | — | — |
| Teams | `com.microsoft.teams2` | — | — | — | — | — | — |
| Notion | `notion.id` | — | — | — | — | — | — |
| Outlook | `com.microsoft.Outlook` | — | — | — | — | — | — |
| WhatsApp | `net.whatsapp.WhatsApp` | — | — | — | — | — | — |
| Telegram | `ru.keepcoder.Telegram` | — | — | — | — | — | — |
| VS Code | `com.microsoft.VSCode` | — | — | — | — | — | — |
| Cursor | `com.todesktop.230313mzl4w4u92` | — | — | — | — | — | — |
| Xcode | `com.apple.dt.Xcode` | — | — | — | — | — | — |
| Firefox | `org.mozilla.firefox` | — | — | — | — | — | — |
| Obsidian | `md.obsidian` | — | — | — | — | — | — |
| Linear | `com.linear` | — | — | — | — | — | — |

## Excluded by default

Not tested for support — deliberately blocked.

| App | Reason |
|---|---|
| Terminal / iTerm / Ghostty | Shell input is not prose |
| 1Password / Bitwarden | Credential surface |
| Keychain Access | Credential surface |
| Any field with `AXSecureTextField` subrole | Enforced globally, not per-app |

---

## Notes

Record anything surprising here — this is what feeds the quirk table in
[05-accessibility-strategy.md](05-accessibility-strategy.md) §8, and eventually
the remote-updatable JSON.

Worth noting specifically:

- Apps where `AX write reported SUCCESS but the text did not change` — the silent
  no-op. Expect this across web content; it's why paste is the default strategy.
- Apps where activation (`AXManualAccessibility` / `AXEnhancedUserInterface`) was
  required, and whether it caused any visible slowdown or window glitching in the
  host app.
- Apps where the tree took longer than ~400ms to become available after activation.
- App version numbers. These behaviours change between releases, so a matrix entry
  without a version is a matrix entry you can't reproduce.

```
Date tested:
macOS version:
Tester:
```
