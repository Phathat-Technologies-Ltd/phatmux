# Architecture Analysis: Warp Clone on Ghostty

## Context

We explored three approaches to building Warp-like features (collapsible
blocks, AI agent UI, mixed rich text, block actions) on top of Ghostty's
terminal emulator.

## Approaches Evaluated

### A: Fork Ghostty + z2d Overlay (what we built)

Modified Ghostty's internal Zig source directly. Split large core files,
added semantic block rendering via the z2d CPU overlay, wired config,
click handling, and LLM integration into the terminal core.

**What works:** Block borders, hover states, copy buttons, active block
tracking. Anything that can be drawn as rectangles on top of the
terminal grid.

**What doesn't work:** Collapsible blocks (terminal grid is linear and
fixed-height), mixed rich text and natural language (grid is monospace
cells), collapsible LLM thought processes, variable-height UI elements,
markdown rendering, proportional fonts, interactive buttons beyond
simple hit zones.

**Maintenance cost:** Every upstream Ghostty commit to Surface.zig,
Terminal.zig, Screen.zig, PageList.zig, Config.zig, or Binding.zig
creates merge conflicts. The file-splitting refactoring makes this
permanent.

**Verdict:** Insufficient for a Warp clone. The terminal grid model
cannot support the target UI.

### B: New App on libghostty-vt (headless VT library)

Build a completely separate application using Ghostty's extracted VT
library (`include/ghostty/vt.h`) as a headless terminal state machine.
Manage PTY, rendering, input, and UI entirely in our code.

**What it provides:** Terminal state machine (VT parsing, screen buffer,
scrollback, cursor, modes), formatter (plain text / VT / HTML output),
key encoder, OSC/SGR parsers. Cross-platform C API.

**What it doesn't provide:** No renderer, no PTY management, no font
engine, no input handling, no window management, no Metal/GPU rendering,
no image protocol support, no OSC 133 semantic prompt callbacks (explicitly
excluded from the API).

**Cost:** Building a terminal renderer from scratch is months of work.
Font rendering, glyph atlas, ligatures, wide characters, image protocols,
cursor rendering, selection, smooth scrolling — all must be reimplemented.

**Verdict:** Viable for cross-platform or web-based tools. Overkill for
a macOS app where the embedded SurfaceView already provides a full
renderer.

### C: New SwiftUI App with Embedded GhosttyKit (recommended)

Build a new macOS SwiftUI application that embeds Ghostty's
`GhosttyKit.xcframework` as a dependency. Use one Ghostty `SurfaceView`
for the live terminal. Use native SwiftUI views for everything else.

**Architecture:**

```
┌─ SwiftUI App ─────────────────────────────────────┐
│                                                     │
│  ScrollView of native Block views                  │
│  ├─ Completed command blocks (NSAttributedString)  │
│  ├─ AI response blocks (SwiftUI rich text)         │
│  ├─ Collapsible thought/code sections              │
│  └─ Block action bars (thumbs, credits, copy)      │
│                                                     │
│  Live Terminal (Ghostty SurfaceView)               │
│  └─ Full Metal GPU rendering, handles vim/ssh/etc  │
│                                                     │
│  Input Bar (native NSTextView)                     │
│  └─ Command input or AI prompt                     │
└─────────────────────────────────────────────────────┘
```

**What it provides:**

- Ghostty's Metal renderer for the live terminal (zero effort)
- `COMMAND_FINISHED` callback with exit code and duration
- `PWD` change tracking
- `read_text` / formatter for extracting completed output
- Full native SwiftUI for block chrome, collapsing, rich text, buttons

**What it costs:**

- New Swift project (but small: SwiftUI app + block model + AI layer)
- ANSI-to-NSAttributedString parser for completed block output
- OSC 133 boundary detection via existing callbacks

**Verdict:** Best performance/capability ratio. Live terminal uses GPU.
Completed blocks use platform-native text. Rich UI features (collapse,
mixed text, buttons) are standard SwiftUI.

## Decision

**Go with approach C.** Keep the existing Ghostty fork with file
splitting intact (the refactoring improves readability regardless).
Build a new SwiftUI app project that consumes GhosttyKit as a framework.

## What Transfers from Current Work

| Asset | Transfers? | Notes |
|-------|-----------|-------|
| Design docs (9 HLDs/LLDs) | Yes | Behavior specs transfer to Swift |
| LLM Engine (Engine.zig) | Yes | Call via C interop or rewrite in Swift |
| Shell integration (zsh) | Yes | OSC 133 hooks work with any terminal |
| Block model thinking | Yes | Maps to Swift ObservableObject |
| z2d overlay code | No | Replaced by native SwiftUI views |
| Zig config wiring | No | App has its own config |
| File-splitting refactor | Keep | Improves upstream code readability |

## Key Risks

1. **Block boundary detection:** Relies on `COMMAND_FINISHED` callback
   accuracy. May need to augment with shell integration signals.
2. **Output extraction timing:** Must extract text between command
   finish and next prompt. Race conditions possible.
3. **Interactive program handoff:** When user runs vim/ssh, the live
   SurfaceView must expand to full window. Detection via alternate
   screen mode.
4. **GhosttyKit API surface:** Some operations (reading specific row
   ranges by semantic markers) may require small upstream patches.
