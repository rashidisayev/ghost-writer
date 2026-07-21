# Making it work — the build runbook

Design docs are in [docs/](docs/). This is the execution path. Do these in order; each step has a gate that tells you whether to continue.

Toolchain on this machine: **Swift 6.3.3** via Command Line Tools, Xcode.app present. You don't need Xcode for steps 1–2.

---

## Step 1 — Grant Accessibility to your terminal (5 minutes)

A command-line tool has no bundle identity of its own, so TCC attributes it to the **parent process**. Whatever terminal you run `ax-probe` from is what needs the grant.

```
System Settings → Privacy & Security → Accessibility
→ enable Terminal (or iTerm, Ghostty, VS Code — whichever you launch from)
```

Then **fully quit and reopen that terminal**. The grant is read at process launch; a running terminal will keep reporting "not trusted" forever.

**Gate:** `./Tools/ax-probe/ax-probe --delay 1` prints `✓ Process is AX-trusted`.

> This is also the first thing your future users will hit, in a slightly different form. Feeling the friction yourself is useful.

---

## Step 2 — Run the compatibility matrix (half a day)

This is Phase 0 from the [roadmap](docs/08-roadmap.md), and it is the single highest-value thing you can do right now. It costs half a day and it tells you whether the product is buildable at all.

```bash
cd Tools/ax-probe
./ax-probe --delay 5              # read-only probe
./ax-probe --delay 5 --write      # also tests whether AX writes actually apply
./ax-probe --delay 5 --all        # dump every attribute, for triage
```

Run it, switch to the target app, click into a text field, type a few words, wait for the countdown. Record the verdict in [docs/compatibility-matrix.md](docs/compatibility-matrix.md).

Test in this order — the first three are the real test:

| # | App | Why it matters |
|---|---|---|
| 1 | **Slack** | Electron. If this fails, the product thesis is in trouble. |
| 2 | **Chrome or Arc** | Chromium + web content. Covers Gmail, Notion web, Linear. |
| 3 | **Safari** | WebKit behaves differently from Chromium. |
| 4 | TextEdit | Native `NSTextView` — the easy case, your control group. |
| 5 | Mail | Native, rich text. |
| 6 | Notes | Native, but a custom text engine. |
| 7 | Discord / Teams | More Electron, different versions. |
| 8 | VS Code / Cursor | Electron with a custom editor — expect failure, confirm it. |

**Gate — be honest about this one:**

- Slack + Chrome + Safari all read → **green, proceed to step 3.**
- Slack fails but browsers work → **narrow the product.** A browser-focused tool is still a real product, and it's a much smaller surface. Rewrite the positioning before writing code.
- Browsers fail too → **stop.** Something is wrong with the environment or the approach; debug with `--all` before building anything on top.

The `--write` verdict matters as much as the read one. Expect to see `AX write reported SUCCESS but the text did not change` in web content — that's the silent no-op that makes the paste strategy mandatory, and seeing it yourself is worth more than reading about it in [05](docs/05-accessibility-strategy.md).

---

## Step 3 — Prove the loop end-to-end (2–3 days)

Before any UI, build a second CLI: `Tools/rewrite-loop`. No windows, no menu bar, no panel.

```
read focused text → extract paragraph → POST to Claude → print the diff to stdout
```

Reuse the reader from `ax-probe` and the provider from [10-code-snippets.md](docs/10-code-snippets.md) §7. Trigger it with a hotkey or just a countdown.

**Why a CLI and not the app:** it isolates the two genuinely uncertain things (AX reading, rewrite quality) from the large pile of certain-but-tedious things (app bundle, panel positioning, settings, login item). If rewrite quality in German and Russian isn't good enough, you want to discover that in three days, not three weeks.

**Gate:** paste 20 real paragraphs of your own writing — in every language you care about — through it and read the output. If the rewrites aren't clearly better than the input, tune the prompt in [10-code-snippets.md](docs/10-code-snippets.md) §6 *now*. Prompt work is much cheaper before there's a UI on top of it.

```bash
export ANTHROPIC_API_KEY=sk-ant-...    # for the CLI only; the app uses Keychain
```

---

## Step 4 — The app shell (1 week)

Now open Xcode. `xcode-select` currently points at Command Line Tools, so switch it first:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

New project → macOS → App → SwiftUI. Then immediately:

1. **`Info.plist`:** add `LSUIElement = YES`. No Dock icon.
2. **Signing & Capabilities:** **remove the App Sandbox.** New projects get it by default and it will silently break every AX call. This is the single most common way to lose an afternoon here.
3. Keep Hardened Runtime **on**.
4. Add the packages from [04-project-structure.md](docs/04-project-structure.md) as local SPM targets.

Build order: menu bar item → permission onboarding → Keychain → settings shell. All boring, all necessary, none of it risky.

**Gate:** launches at login, no Dock icon, survives a reboot, reports permission state correctly.

---

## Step 5 — Wire it together (1–2 weeks)

Port the CLI logic into the packages, then add in this order:

1. `FocusTracker` + `TextReader` ([10](docs/10-code-snippets.md) §2–3)
2. `PolicyEngine` — **before** the provider is connected. Log what *would* be sent and read those logs for a day.
3. `KeystrokeMonitor` + debounce ([10](docs/10-code-snippets.md) §4)
4. `ClaudeProvider` ([10](docs/10-code-snippets.md) §7)
5. `SuggestionPanel` ([10](docs/10-code-snippets.md) §9) — the trickiest UI piece; `orderFrontRegardless()`, never `makeKeyAndOrderFront`
6. `TextWriter` ([10](docs/10-code-snippets.md) §8) — paste strategy first, AX write as the optimization

**Gate:** you use it yourself, all day, for a week, without disabling it.

---

## Step 6 — Ship (1 week)

```bash
# Sign
codesign --force --deep --options runtime \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" GhostWriter.app

# Notarize
xcrun notarytool submit GhostWriter.zip \
  --keychain-profile "AC_PASSWORD" --wait

# Staple
xcrun stapler staple GhostWriter.app
```

Requires a paid Apple Developer account ($99/yr) for the Developer ID certificate. Put notarization in CI and make its failure break the build — an un-notarized build reaching a user is a conversion killer, and it fails quietly.

Then Sparkle for updates, a DMG, and a payment provider. Remember there is no App Store path ([09](docs/09-risks.md) §1).

---

## The order matters

The sequencing here is deliberate: **every uncertain thing happens before every tedious thing.** Steps 2 and 3 cost about four days combined and retire essentially all the technical risk in the project. Steps 4–6 are five weeks of work that is entirely predictable.

The common failure mode for a project like this is building the app shell first, because it feels like progress and it's the part you already know how to do. Then you discover in week four that Slack's accessibility tree doesn't give you what you need, and the four weeks were spent on scaffolding for something that can't stand.

Run the probe first.
