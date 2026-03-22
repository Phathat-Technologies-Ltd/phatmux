---
name: debugging-phatmux-application
description: >-
  Explains how to debug the phatmux macOS app (SwiftUI + AppKit + libghostty):
  tagged reload workflow, unified debug log, temporary instrumentation, lldb
  attachment, and build/cache pitfalls (xcframework, bridging header, DerivedData).
  Use when the user asks how to debug phatmux, diagnose focus/input issues, trace
  Ghostty integration, or fix "stale build" / missing Swift symbols after Zig
  or header changes.
---

# Debugging phatmux

## Before you guess

1. **Reproduce with an isolated app** — always `./scripts/reload.sh --tag <slug>`. Never rely on an untagged `phatmux DEV.app` (shared socket, bundle ID, focus theft). See `AGENTS.md` "Local dev".
2. **Confirm which layer changed** — Zig (`ghostty/`), root bridge header (`ghostty.h`), or Swift (`Sources/`). Wrong layer → wrong fix. See repo rule `build-and-shell-safety`.
3. **Prefer evidence** — tail the debug log, add short-lived `dlog` lines, or attach `lldb` before rewriting architecture.

## Run / isolate

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

Compile-only (no launch), still use a dedicated DerivedData path:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme phatmux -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/phatmux-<tag> build
```

## Unified debug event log (DEBUG builds)

- **Tail current file** (reload writes the path):

```bash
tail -f "$(cat /tmp/phatmux-last-debug-log-path 2>/dev/null || echo /tmp/phatmux-debug.log)"
```

- **Typical paths**: untagged `/tmp/phatmux-debug.log`; tagged `/tmp/phatmux-debug-<tag>.log`.
- **Implementation**: `vendor/bonsplit/.../DebugEventLog.swift`; **`dlog("…")`** appends with timestamp. Every call site must sit inside `#if DEBUG` … `#endif`.
- **Use for**: focus moves, key/mouse routing, tab/split events — not for hot per-keystroke spam in latency-sensitive paths (see `AGENTS.md` "Pitfalls").

## Temporary instrumentation

- Add **narrow** `dlog` messages at boundaries: Swift callback entry, `onPtyOutput`, alt-screen toggles, paste/submit paths. Remove before merge unless product asks for permanent logging.
- For **Zig / libghostty** investigation, short-lived `std.log` or tracing is fine during diagnosis; strip or gate before shipping unless the fork policy says otherwise.
- **Do not** add work inside `TerminalSurface.forceRefresh()` or other paths documented as typing-hot in `AGENTS.md`.

## lldb (when logs are not enough)

1. Build and launch with `./scripts/reload.sh --tag <tag>`.
2. Find PID: `pgrep -f "phatmux DEV <tag>"` (adjust pattern to match the tagged app name).
3. Attach: `lldb -p <pid>`.
4. **First commands**: `bt all` or `thread list` + `bt` on the interesting thread; for focus issues, break on `becomeFirstResponder` / `makeFirstResponder` only if you have a symbol-friendly build.

Use lldb when the process **stops updating**, **hangs**, or Swift-side callbacks **silence** after a thread hop — verify whether you are touching AppKit/Swift objects off the main thread.

## Stale builds and "missing" C API in Swift

Symptoms: Swift errors for symbols that exist in `ghostty.h`, or runtime behavior that ignores fresh Zig changes.

**Layers** (each has its own cache):

1. Zig → `ghostty/macos/GhosttyKit.xcframework/` (rebuild from `ghostty/` with the project's documented `zig build` flags — see `AGENTS.md`).
2. **`ghostty.h`** — must stay in sync with `ghostty/include/ghostty.h` when the C API changes; the bridging header imports the **root** `ghostty.h`.
3. Xcode DerivedData for the **tagged** app — delete `~/Library/Developer/Xcode/DerivedData/phatmux-<tag>` and reload.

**Sanity-check the binary** (optional):

```bash
strings "/path/to/phatmux DEV <tag>.app/Contents/MacOS/phatmux DEV <tag>" | grep "unique-marker"
```

## Focus, keyboard, and overlays

Read **`AGENTS.md` → Pitfalls**:

- Local event monitor vs responder chain (overlays that need keys).
- `activeBlockSessionManager` and focus-dependent routing.
- Ghostty surface as first responder — mixed SwiftUI/AppKit layering.

## Socket / CLI tests against a running app

Python socket tests need a **tagged** socket, e.g. `PHATMUX_SOCKET=/tmp/phatmux-debug-<tag>.sock`. Do not drive tests against an untagged dev instance if another agent or the user already has one.
