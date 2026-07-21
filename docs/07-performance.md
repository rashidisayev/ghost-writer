# Performance Plan

## 1. Budgets

These are commitments, not aspirations. Each has a test in the latency harness.

| Metric | Budget | Measured how |
|---|---|---|
| Added keystroke latency | **0 ms** (unmeasurable) | Event tap is listen-only; never in the delivery path |
| Event tap callback duration | < 50 µs p99 | `signposts` around the callback |
| Idle CPU | < 0.1% | 10-min idle sample in Activity Monitor |
| Active typing CPU | < 2% | Sustained 60 WPM typing |
| Idle RSS | < 60 MB | Steady state after 1h |
| Peak RSS | < 120 MB | With overlay + settings open |
| Suggestion round-trip p50 | < 1.2 s | Haiku 4.5, 60-word paragraph |
| Suggestion round-trip p95 | < 2.5 s | Same |
| Cache hit latency | < 5 ms | End-to-end, cached path |
| Energy impact | "Low" in Activity Monitor | Sustained use |

The 0 ms keystroke budget is the one that matters most. Users forgive slow suggestions; they uninstall over laggy typing.

## 2. Never block typing

The event tap is created with `.listenOnly`, which means the system does not wait for Ghost Writer before delivering the keystroke. Even so, the callback is written as if it were in the path:

```swift
// The ENTIRE callback body. No allocation, no locks, no logging.
let cb: CGEventTapCallBack = { _, type, _, refcon in
    if type == .keyDown {
        let box = Unmanaged<TickBox>.fromOpaque(refcon!).takeUnretainedValue()
        box.lastKeystroke.store(mach_absolute_time(), ordering: .relaxed)
    }
    return nil   // listen-only: return value ignored, event unmodified
}
```

One atomic store. No `Date()`, no dictionary lookup, no `os_log`. The orchestrator polls the atomic on its own timer; the tap never calls into it.

macOS disables an event tap that is too slow (`tapDisabledByTimeout`) — Ghost Writer listens for that event type and re-enables the tap, logging it as a defect to investigate rather than treating it as routine.

## 3. Reducing AX cost

AX calls are synchronous IPC to the target process. They are the second-biggest performance risk after the tap.

- **Timeout everything.** `AXUIElementSetMessagingTimeout(element, 0.25)` on every element. A hung target app must not hang Ghost Writer's main thread.
- **Read the range, not the field.** `kAXStringForRangeParameterizedAttribute` around the caret rather than `kAXValueAttribute` on the whole buffer. On a 200KB document this is the difference between ~40 ms and ~0.5 ms per pass.
- **Cheap change detection.** `kAXNumberOfCharactersAttribute` is far cheaper than pulling the value. Compare length and caret offset first; only pull text when one of them moved meaningfully.
- **Never poll.** All focus changes come from `AXObserver` notifications. Polling the AX tree at any interval is how these apps end up at 5% idle CPU.
- **Disable enhanced accessibility when idle.** Chromium/Electron trees are expensive for the *host* app. Turn the attribute off after 5 minutes without editable focus in that app — this is a performance fix for the user's other apps, which they will attribute to Ghost Writer either way.

## 4. Debouncing and cancellation

```
keystroke → reset 700ms timer → fire → read → hash → cache? → request
              ↑                                                  │
              └──────── new keystroke cancels in-flight task ─────┘
```

Two independent guards against wasted requests:

1. **Time debounce** — 700 ms of quiet. Tuned from the observation that mid-word pauses cluster under 400 ms and end-of-thought pauses cluster above 800 ms.
2. **Change threshold** — at least 25 characters changed since the last pass, or a sentence terminator typed. Prevents a request every time someone fixes a typo.

Cancellation is structured concurrency, so it propagates into `URLSession` and actually aborts the HTTP request rather than just discarding the result:

```swift
inFlight?.cancel()
inFlight = Task { [weak self] in
    let result = try await provider.rewrite(request)   // throws CancellationError
    try Task.checkCancellation()
    await self?.present(result)
}
```

## 5. Caching

Two layers.

**Rewrite cache** — `NSCache`, 200 entries, keyed on `SHA256(normalizedText ‖ toneID ‖ aggressiveness ‖ modelID ‖ promptVersion)`. Normalization collapses whitespace runs and strips trailing spaces, which is what makes it hit while the user is still fiddling with the paragraph. `promptVersion` in the key means a prompt change invalidates the whole cache automatically — a bug that is very annoying to find otherwise.

Expected hit rate is high in practice, because the dominant pattern is: trigger, look at the suggestion, keep typing elsewhere in the paragraph, trigger again on nearly the same text.

**Prompt caching (server-side)** — Anthropic's prompt cache has a minimum cacheable prefix of 4096 tokens on Opus 4.8 and 2048 on Sonnet 4.6/Fable 5. A tone profile plus the base instructions is a few hundred tokens, well under either floor, so **`cache_control` on the system prompt will silently do nothing** for the default configuration. Do not add it and assume a win — verify with `usage.cache_read_input_tokens` before claiming any benefit. It becomes worthwhile only if a user attaches a large style guide or glossary to a tone profile, which is the v2 case where it should be added conditionally.

This is exactly the kind of thing worth measuring rather than assuming; a `cache_control` block that never fires costs nothing but also delivers nothing, and it is easy to believe it is working.

## 6. Model selection and latency

| Model | Role in the product | Notes |
|---|---|---|
| **Claude Opus 4.8** (`claude-opus-4-8`) | Default — best rewrite quality, strongest multilingual | Supports fast mode (up to ~2.5× output tok/s) at premium pricing |
| **Claude Sonnet 5** (`claude-sonnet-5`) | Balanced option in Settings | |
| **Claude Haiku 4.5** (`claude-haiku-4-5`) | "Fastest" option; good fit for Light aggressiveness | Lowest cost, lowest latency |

Latency levers, in order of impact:

1. **Bound the input.** One paragraph, not the document. This is worth more than every other lever combined.
2. **Bound the output.** `max_tokens` sized to `inputTokens * 1.4 + 64`. A rewrite is roughly the same length as its input; letting the model run to 4096 tokens invites a runaway.
3. **No thinking.** On Opus 4.8, omitting the `thinking` parameter runs without thinking — which is what this workload wants. Do not set `thinking: {"type": "adaptive"}` here; deliberation adds seconds and does not improve a grammar-and-clarity rewrite.
4. **`output_config: {"effort": "low"}`** for Light aggressiveness, `"medium"` for Balanced. Higher effort is wasted on this task.
5. **Fast mode** for Opus 4.8 when the user opts in: beta header `fast-mode-2026-02-01` plus `speed: "fast"` on `client.beta.messages`. Premium pricing, separate rate limit — fall back to standard on 429.
6. **Connection reuse.** One long-lived `URLSession`; HTTP/2 keep-alive removes ~100–200 ms of TLS handshake per request.
7. **Warm the connection** on focus-gain of an editable field, before the user finishes typing. A zero-cost `HEAD`-equivalent or simply keeping the session warm hides the handshake entirely.

Note that `temperature`, `top_p`, and `top_k` are rejected with a 400 on Opus 4.8, Opus 4.7, and Sonnet 5 — steer output style through the prompt, not sampling parameters.

## 7. Memory

- `NSCache` responds to system memory pressure automatically; do not hand-roll eviction.
- The suggestion card panel is created once and reused, not rebuilt per suggestion. `NSPanel` creation is not cheap and this path runs dozens of times an hour.
- Release `AXUIElement` references on focus change — they retain a Mach port to the target process, and leaking them shows up as steadily climbing port counts rather than as RSS growth, which makes it easy to miss.
- SwiftUI settings views are torn down when the window closes; don't hold them alive to "make reopening fast."
- Cap the recent-suggestions ring buffer at 20 entries and store only the diffed spans, not full before/after text.

## 8. Energy

- No timers when there is no editable focus. The debounce timer exists only while a field is focused, and is invalidated the moment focus leaves.
- Fully dormant when the screen is locked or the display sleeps (`NSWorkspace.willSleepNotification`, `screensDidSleepNotification`).
- On battery below 20%, extend the debounce to 1200 ms and disable automatic triggering in favour of manual hotkey. Announce this in the menu bar rather than doing it silently.

## 9. Measurement

- `os_signpost` intervals around: tap callback, AX read, scope resolve, cache lookup, network, diff, present, apply. This gives a per-stage flame graph in Instruments with no extra tooling.
- `Tools/latency-bench` replays a fixture corpus (60 paragraphs × 6 languages) against each model and reports p50/p95/p99 plus token cost. Run per release; regressions here are product regressions.
- A hidden debug HUD (`⌥⌘D`) showing last-pass timings, cache hit/miss, and the chosen write strategy. Indispensable for triaging user reports about specific apps.
