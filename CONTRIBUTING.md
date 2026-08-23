# Developing PopChat

PopChat is built for personal use and shared as-is, so there is no roadmap and no guarantee a pull request gets merged — but bug reports are welcome, and if you want to build on it yourself, this is what you need to know.

## Layout

Plain SwiftPM, no Xcode project. `Package.swift` builds a single executable target; `build.sh` wraps the binary in an app bundle (`LSUIElement`, ad-hoc signed) and `release.sh` does the Developer-ID + notarization path.

```
Sources/PopChat/         AppKit shell, SwiftUI views, Theme
Sources/PopChat/Chat/    providers, streaming clients, stores, web tools
Resources/               Info.plist, app icon
Tools/                   fake app-server fixtures used by the smoke harnesses
```

`KeyboardShortcuts` is pinned to exactly 1.15.0: later versions use `#Preview` macros, which need full Xcode and fail to compile with the Command Line Tools alone.

`build.sh` passes `--build-system swiftbuild`, and that is not a speed preference — do not drop it. SwiftPM generates the `Bundle.module` accessor differently per build engine. The default native engine emits the flavour written for a command-line tool, which looks for the resource bundle beside the executable and then at the absolute build directory of whoever compiled it. Inside an app bundle, "beside the executable" is `PopChat.app/` — and nothing may live at the root of a signed `.app`, because `codesign` refuses to seal it. So that candidate can never be satisfied, and every build fell through to the second one, which exists only on the build machine. Shipped copies trapped the moment the user opened the hotkey recorder. The `swiftbuild` engine emits the flavour Xcode uses, which looks in `Bundle.main.resourceURL` — `Contents/Resources`, where `build.sh` puts them.

Because that failure is invisible on the machine that built it, `build.sh` runs `--smoke-bundles` against the packaged app before signing. Run by hand it only means something from inside `dist/PopChat.app`; a loose `.build/debug/PopChat` finds the bundles sitting next to it and passes either way.

## Test harnesses

`swift build` produces `.build/debug/PopChat`, which doubles as a headless test harness — there is no XCTest suite; the flags below are the test suite.

```sh
POPCHAT_API_KEY=… .build/debug/PopChat --smoke              # live streaming round-trip
POPCHAT_API_KEY=… .build/debug/PopChat --smoke-search       # tool-calling loop
.build/debug/PopChat --smoke-file <path>                    # attachment extraction
.build/debug/PopChat --smoke-typing                         # composer latency budget
.build/debug/PopChat --smoke-scroll                         # transcript scroll perf
.build/debug/PopChat --smoke-find                           # find-in-chat behavior
.build/debug/PopChat --smoke-history-bench [convs] [images] # conversation-store startup cost
.build/debug/PopChat --smoke-history-search                 # cross-conversation full-text search
```

`--smoke-history-bench` synthesizes a store and times what the launch path calls.
Listing history must stay flat as the store grows: it reads metadata columns only,
so neither message bodies nor attachment blobs are on that path. If it starts
tracking store size again, something has put a body back into the list query.
Set `POPCHAT_BENCH_DIR` to keep the generated store — measuring in the same
process that just bulk-inserted it measures a hot write-ahead log, not a launch.

```sh
dist/PopChat.app/Contents/MacOS/PopChat --smoke-bundles     # packaging: dependency resources resolve
```

`--smoke-persist`, `--smoke-history`, `--smoke-minsize`, `--smoke-pasteable`, `--smoke-providers`, `--smoke-accent`, `--smoke-typewriter`, `--smoke-ephemeral`, `--chatgpt-login` and `--smoke-chatgpt` cover the rest. `--check-codex-app-server` checks the installed Codex, ChatGPT login and available model catalog without starting a model turn; `--smoke-codex-refresh-coalescing` verifies overlapping checks share one process. `--shot <settings|general|switcher> <path> [--dark|--light]` renders a view to PNG in-process.

Four harnesses drive a fake app-server instead of the real one, so they cost no subscription quota and need no Codex install:

```sh
.build/debug/PopChat --smoke-codex-app-server-streaming    Tools/fake-codex-stream
.build/debug/PopChat --smoke-codex-app-server-timeout      Tools/fake-codex-stall
.build/debug/PopChat --smoke-codex-app-server-backpressure Tools/fake-codex-wedge
.build/debug/PopChat --smoke-codex-app-server-session      Tools/fake-codex-session
```

They guard, in order: turn assembly and notification ordering (both agent messages must survive, the first delta must not wait on the `turn/start` response, a replayed `item/completed` must not duplicate its item, and a `willRetry` error must drop the aborted in-flight partial and surface a retry status rather than gluing the re-stream onto it in silence); recovery from a process that goes silent mid-turn; the rule that a process which stops draining its stdin cannot wedge PopChat — never hold a lock across the blocking write, or Stop and the watchdog both block behind it; and session reuse.

That last one is worth explaining, because what it protects is invisible from the outside. `CodexAppServerBackend` keeps one `codex` process and one ephemeral thread alive across a conversation's turns, because the backend's prompt cache keys off the session: a reused thread reports most of its input cached, two fresh threads with an identical prefix report none. So a regression that quietly respawns per turn still produces correct answers — it just costs several times the tokens and seconds of extra latency, and no test that only reads the reply would notice. The harness counts protocol methods and pids instead: reuse sends one `thread/start` and no re-injection; a transcript that no longer matches what the thread was told rebuilds the thread but keeps the process; toggling web search (a launch argument) starts a new process; a `turnId`-less server must still stream; a turn cancelled via `turn/interrupt` must leave the child alive without its cancellation timer killing the turn that follows; and an idle session must retire its child. That last one matters because the store's staleness reset only runs when the panel is summoned — a conversation that is simply abandoned would otherwise leave `codex` resident indefinitely, so the backend's own idle timer is the only thing that retires it.

`--smoke-codex-app-server-cache` proves the same claim end to end against the real Codex, and prints the cached-token counts it asserts on. It costs a little quota, so it is not part of the routine loop.

Two rules when running these:

- Each GUI harness builds a real key window, so **run them one at a time**, not back-to-back — otherwise they fight over key status and stray keystrokes land in the wrong field, failing spuriously.
- The performance harnesses fail on main-thread stalls, so run `--smoke-typing` and `--smoke-scroll` after touching the transcript, the composer or panel sizing.

## Performance constraints

Responsiveness is a hard requirement, and several obvious-looking changes break it badly. Before touching the transcript or composer, know that: the transcript is a plain `VStack` (a `LazyVStack` fights `NSScrollView` into a freeze), message rows are `Equatable`-gated so a streaming tick re-renders only the changed row, the root `NSHostingView` has `sizingOptions = []` so composer resizing can't re-measure the whole tree, and panel show/hide animates a `CALayer` transform rather than the window frame. Visual fidelity matters; implementation fidelity does not — prefer the cheapest technique that looks the same.

## Releasing

`./release.sh` builds, signs with a Developer ID, notarizes and staples both the app and the disk image, then verifies it as Gatekeeper would. It needs a stored notarytool profile (see the header comment in the script) and only works with my certificate.
