# UI Wireframes

ASCII wireframes. Dimensions are logical points at 1× and assume the system font stack (SF Pro / SF Mono for code spans).

## 1. Suggestion card — the primary surface

Anchored 8pt below the caret rect. Width clamps to `min(480, fieldWidth)`. Non-activating panel; the host app keeps key focus.

```
                    ▲  (caret in the user's text field)
┌──────────────────────────────────────────────────────────────┐
│  ✦ Professional          Deutsch              ⌘⏎ alternatives│  ← 24pt header, tertiary label
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Ich ~~hab~~ **habe** die Unterlagen ~~geschickt an dich~~    │
│  **an Sie geschickt** und ~~wollte fragen ob~~ **möchte**     │
│  **nachfragen, ob** Sie noch Fragen ~~haben~~ **haben.**      │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  ⇥ Accept          ⎋ Dismiss              4 changes · 0.8s   │
└──────────────────────────────────────────────────────────────┘
```

- Strikethrough red = removed. Bold green = added. Unchanged text at normal weight.
- Header shows active tone profile (click to change inline) and detected language.
- Footer shows change count and round-trip latency — latency is deliberately visible; it builds trust that nothing is happening in the background you can't see.
- Materials: `.hudWindow` visual effect, 10pt corner radius, 1px `separatorColor` border.

**Alternatives view** (`⌘↩`):

```
┌──────────────────────────────────────────────────────────────┐
│  ✦ Professional          Deutsch                    2 of 3   │
├──────────────────────────────────────────────────────────────┤
│  ○ ─────────────────────────────────────────────────────────│
│  ● Ich habe die Unterlagen an Sie geschickt und möchte       │
│    nachfragen, ob Sie noch Fragen haben.                     │
│  ○ ─────────────────────────────────────────────────────────│
├──────────────────────────────────────────────────────────────┤
│  ↑↓ Browse    ⇥ Accept    ⎋ Dismiss                          │
└──────────────────────────────────────────────────────────────┘
```

## 2. Underline overlay

Click-through panel drawn over the host field. Only rendered when per-range rects are available (native AppKit text views, some Electron builds with accessibility fully enabled).

```
   The quaterly report was sent to the stakeholders yesterday
       ~~~~~~~~~                    ~~~~~~~~~~~~
       (2pt underline, accent color, 60% opacity)
```

When rects are unavailable, degrade to a single 6pt dot at the caret rather than guessing positions. Drawing an underline in the wrong place is worse than drawing nothing.

## 3. Menu bar

Icon: a monoline feather/pen glyph. Template image so it adapts to light/dark and to menu bar tinting. Three states: active (filled), paused (outline), error (outline + small badge).

```
┌────────────────────────────────────┐
│  ● Ghost Writer is active                 │
│                                    │
│  Tone   Professional            ▸  │
│  ─────────────────────────────────  │
│  Pause for 30 minutes              │
│  Disable in Slack                  │
│  ─────────────────────────────────  │
│  Recent suggestions             ▸  │
│  Today: 34 shown · 71% accepted    │
│  ─────────────────────────────────  │
│  Settings…                     ⌘,  │
│  Quit Ghost Writer                    ⌘Q  │
└────────────────────────────────────┘
```

"Disable in Slack" is context-aware — it names whatever app was frontmost when the menu opened. One click to exclude the app you're currently annoyed in is the single highest-value affordance in the menu.

## 4. Settings — General

```
┌─ Ghost Writer Settings ─────────────────────────────────────────────────┐
│ [General] Triggers  Tones  Languages  Exclusions  AI  Privacy    │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Startup      ☑ Launch at login                                 │
│                ☑ Show menu bar icon                              │
│                                                                  │
│   Default tone  [ Professional        ▾ ]                        │
│                                                                  │
│   Rewrite       ○ Light — grammar and spelling only              │
│   aggressiveness ● Balanced — clarity and word choice            │
│                 ○ Bold — restructure freely                      │
│                                                                  │
│   Suggestions   ● Automatic (on pause)                           │
│                 ○ Manual only (⌥Space)                           │
│                                                                  │
│   ─────────────────────────────────────────────────────────────  │
│   Permissions                                                    │
│     Accessibility        ✓ Granted        [ Open Settings… ]     │
│     Input Monitoring     ⚠ Not granted    [ Grant… ]             │
│         Needed to detect typing pauses. Ghost Writer never records       │
│         keystrokes — only the time of the last one.              │
└──────────────────────────────────────────────────────────────────┘
```

Permission rows live in General, not buried in a Privacy tab, because a missing permission is the #1 cause of "the app doesn't work" and it must be self-diagnosing.

## 5. Settings — Tone Profiles

```
┌─ Ghost Writer Settings ─────────────────────────────────────────────────┐
│ General  Triggers  [Tones]  Languages  Exclusions  AI  Privacy   │
├─────────────────────┬────────────────────────────────────────────┤
│ ✦ Professional  ★   │  Name  [ Engineering Manager            ]  │
│ ✦ Business          │  Icon  [ 🛠 ]                              │
│ ✦ Friendly          │                                            │
│ ✦ Funny             │  Instructions                              │
│ ✦ Formal            │  ┌──────────────────────────────────────┐  │
│ ✦ Casual            │  │ Write as an experienced engineering  │  │
│ ✦ Executive         │  │ manager. Lead with the decision or   │  │
│ ✦ Technical         │  │ ask, then the reasoning. Prefer      │  │
│ ✦ Sales             │  │ concrete nouns over abstractions.    │  │
│ ✦ Marketing         │  │ No hedging, no filler openers.       │  │
│ ✦ Support           │  └──────────────────────────────────────┘  │
│ 🛠 Eng Manager      │                                            │
│                     │  Apply automatically in                    │
│ [ + ]  [ – ]        │  ┌──────────────────────────────────────┐  │
│                     │  │ Slack.app                        [–] │  │
│                     │  │ github.com                       [–] │  │
│                     │  │ [ + Add app or website ]             │  │
│                     │  └──────────────────────────────────────┘  │
│                     │                                            │
│                     │  Preview                                   │
│                     │  ┌──────────────────────────────────────┐  │
│                     │  │ Before: i think maybe we should      │  │
│                     │  │ probably look at moving the deploy   │  │
│                     │  │ After:  We should move the deploy    │  │
│                     │  │ to Thursday — Wednesday collides     │  │
│                     │  │ with the platform freeze.            │  │
│                     │  └──────────────────────────────────────┘  │
│                     │              [ Test with sample text ]     │
└─────────────────────┴────────────────────────────────────────────┘
```

Live preview against a fixed sample is what makes prompt authoring tractable for non-technical users. Without it, writing a tone profile is blind.

## 6. Settings — Exclusions

```
│   Applications                                                   │
│   ┌────────────────────────────────────────────────────────────┐ │
│   │  1Password                                       [ – ]     │ │
│   │  Terminal                                        [ – ]     │ │
│   │  Xcode              (source editor only)         [ – ]     │ │
│   │  [ + Add application… ]                                    │ │
│   └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│   Websites                                                       │
│   ┌────────────────────────────────────────────────────────────┐ │
│   │  *.bank.com                                      [ – ]     │ │
│   │  mail.internal.corp                              [ – ]     │ │
│   │  [ + Add domain… ]                                         │ │
│   └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│   ☑ Never run in password fields            (always on)          │
│   ☑ Skip text that looks like a credential or key                │
│   ☑ Skip fields in private browsing windows                      │
```

Terminal and 1Password ship pre-excluded. "Always on" rows are shown but disabled — visible guarantees are worth the pixels.

## 7. Settings — AI Provider

```
│   Provider     ● Claude (Anthropic)                              │
│                ○ Local model                    (coming soon)    │
│                                                                  │
│   API key      [ ••••••••••••••••••••••••••  ]  [ Verify ]       │
│                Stored in your macOS Keychain. Never synced.      │
│                ✓ Verified · 12 ms                                │
│                                                                  │
│   Model        [ Claude Opus 4.8              ▾ ]                │
│                  Claude Opus 4.8   — best quality                │
│                  Claude Sonnet 5   — balanced                    │
│                  Claude Haiku 4.5  — fastest, lowest cost        │
│                ☑ Use fast mode when available                    │
│                                                                  │
│   Spend        Estimated this month: $2.14                       │
│                ☑ Warn me at [ $10.00 ]                           │
```

## 8. Onboarding

Four screens, no account required, no email gate.

```
1  What Ghost Writer does          → single animated demo of a rewrite in Slack
2  Grant Accessibility      → explains exactly what is read, deep-links to
                              System Settings, polls until granted
3  Grant Input Monitoring   → explains the timestamp-only contract, offers
                              "Skip — use manual hotkey only" as a real option
4  Add your Claude API key  → paste, verify, pick a default tone. Done.
```

Screen 3 offering a genuine skip path matters: users who decline Input Monitoring get a fully working manual-hotkey product rather than a broken one, and being given that choice honestly is what earns the permission from the ones who do grant it.
