# Plan: Warp Clone PoC — Native SwiftUI + Embedded Ghostty

## Goal

Prove that a SwiftUI app embedding Ghostty's SurfaceView gives us full
control over the UI that was impossible with the overlay approach.
Specifically: collapsible blocks, natural language responses, LLM
thought process disclosure, thumbs up/down feedback, and credits
tracking — all with native look and feel.

## Target UI

Based on the Warp AI agent interface:

```
┌─────────────────────────────────────────────────────────┐
│  ┌─ User Ask ────────────────────────────────────────┐  │
│  │  👤 remove nmap and ncat                          │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ AI Response Block ───────────────────────────────┐  │
│  │  ▶ Thought for 1 second                           │  │
│  │                                                    │  │
│  │  ┌─ Command Execution ─────────────────────────┐  │  │
│  │  │ ✅ ssh user@host 'sudo rpm -e nmap ncat'    │  │  │
│  │  │  ▶ (collapsed output — click to expand)     │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  │                                                    │  │
│  │  Both removed. I'll also clean up /tmp:            │  │
│  │                                                    │  │
│  │  ┌─ Command Execution ─────────────────────────┐  │  │
│  │  │ ❌ ssh user@host 'rm /tmp/nmap-*.rpm ...'   │  │  │
│  │  │  ▼ Permission denied: /tmp/nmap-7.94-1...   │  │  │
│  │  │    rm: cannot remove '/tmp/nmap-ncat-7...'  │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  │                                                    │  │
│  │  👍 👎                          39 credits (+3.8) │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ User Ask ────────────────────────────────────────┐  │
│  │  👤 maybe you didn't do sudo?                     │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ AI Response Block ───────────────────────────────┐  │
│  │  ▶ Thought for 1 second                           │  │
│  │                                                    │  │
│  │  ┌─ Command Execution ─────────────────────────┐  │  │
│  │  │ ✅ ssh user@host 'sudo rm -f /tmp/nmap*'   │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  │                                                    │  │
│  │  Done, cleaned up with sudo this time.             │  │
│  │                                                    │  │
│  │  👍 👎                          12 credits (+1.2) │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ Live Terminal ───────────────────────────────────┐  │
│  │  user@host:~$  █                                  │  │
│  │  (Ghostty SurfaceView — Metal GPU rendered)       │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ Input Bar ───────────────────────────────────────┐  │
│  │  > Ask AI or type command...                [⌘K]  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Phase 0: Project Scaffold (day 1)

### 0.1 Create a new Xcode project

- macOS SwiftUI app, call it `GhostWarp` (or whatever name)
- Sits in a new directory: `/Users/amitpaz/dev/ghostwarp/`
- Separate repo from the Ghostty fork

### 0.2 Embed GhosttyKit

- Build the xcframework: `cd /Users/amitpaz/dev/ghostty && zig build`
- Copy or symlink `GhosttyKit.xcframework` into the new project
- Import `GhosttyKit` in Swift
- Verify: create one `Ghostty.SurfaceView`, display it, type `ls`

### 0.3 Minimal app structure

```
GhostWarp/
├── GhostWarpApp.swift          # @main entry point
├── Models/
│   ├── Block.swift             # Block data model
│   ├── Session.swift           # Terminal session + block list
│   └── AIEngine.swift          # LLM integration
├── Views/
│   ├── MainView.swift          # Top-level layout
│   ├── BlockListView.swift     # ScrollView of blocks
│   ├── BlockView.swift         # Single block container
│   ├── UserAskView.swift       # User prompt bubble
│   ├── AIResponseView.swift    # AI response with sub-blocks
│   ├── CommandBlockView.swift  # Command + collapsible output
│   ├── ThoughtView.swift       # Collapsible LLM thinking
│   ├── BlockFooterView.swift   # Thumbs up/down + credits
│   ├── LiveTerminalView.swift  # Wraps Ghostty SurfaceView
│   └── InputBarView.swift      # Bottom input field
└── Utilities/
    ├── ANSIParser.swift        # ANSI escape → NSAttributedString
    └── ShellBridge.swift       # PTY / command execution helper
```

**Success criteria for Phase 0:** A window with a Ghostty terminal at
the bottom and a native text input bar. Typing in the input bar sends
text to the terminal. The terminal works normally.

## Phase 1: Block Model + Static UI (days 2-3)

### 1.1 Block data model

```swift
enum BlockContent: Identifiable {
    case userAsk(UserAsk)
    case aiResponse(AIResponse)
    case commandResult(CommandResult)
}

struct UserAsk: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: Date
}

struct AIResponse: Identifiable {
    let id = UUID()
    var thinking: ThinkingBlock?
    var contentSegments: [ResponseSegment]
    var feedback: Feedback?
    var creditsUsed: Double
}

enum ResponseSegment: Identifiable {
    case text(String)
    case command(CommandExecution)
}

struct CommandExecution: Identifiable {
    let id = UUID()
    let command: String
    var output: NSAttributedString?
    var exitCode: Int?
    var duration: TimeInterval?
    var isExpanded: Bool = false
}

struct ThinkingBlock {
    var durationSeconds: Double
    var content: String
    var isExpanded: Bool = false
}

struct Feedback {
    var thumbsUp: Bool?
}
```

### 1.2 Static block views (hardcoded data)

Build all the SwiftUI views with hardcoded mock data first. No terminal
integration yet. This proves we have full UI control.

- `UserAskView`: Rounded rectangle with user icon and text
- `AIResponseView`: Container with optional thinking disclosure,
  content segments, and footer
- `CommandBlockView`: Command line with status icon (green check /
  red X), collapsible output area with ANSI-colored text
- `ThoughtView`: `DisclosureGroup` showing "Thought for N seconds"
  when collapsed, full thinking text when expanded
- `BlockFooterView`: Thumbs up/down buttons + credits label
- `BlockListView`: `ScrollView` + `LazyVStack` of `BlockContent` items

**Success criteria for Phase 1:** A scrollable list of mock blocks that
look like the Warp AI agent UI. Blocks collapse and expand. Thumbs
up/down toggles. Credits display. All pure SwiftUI, no terminal.

## Phase 2: ANSI Rendering + Command Execution (days 4-5)

### 2.1 ANSI parser

Build a lightweight ANSI escape code parser that converts terminal
output (with SGR color codes) into `NSAttributedString`. This is for
rendering completed command output in native text views.

Scope: SGR colors (16, 256, RGB), bold, italic, underline, dim. No
need for cursor movement, alternate screen, or other VT sequences —
those are only relevant for the live terminal.

Alternatively, use `ghostty_formatter_format_alloc` with
`GHOSTTY_FORMATTER_FORMAT_HTML` and parse the HTML into attributed
string. This gives us Ghostty-accurate rendering for free.

### 2.2 Command execution bridge

Create `ShellBridge` that can:
1. Execute a command string via the Ghostty surface (write to PTY)
2. Or execute independently via `Process` / `posix_spawn` for AI-driven
   commands that should not go through the interactive terminal

For the PoC, start with `Process`-based execution:

```swift
func executeCommand(_ cmd: String, in directory: String) async
    -> (output: String, exitCode: Int32, duration: TimeInterval)
```

This keeps AI-executed commands separate from the live terminal, which
is cleaner and avoids the OSC 133 boundary problem entirely.

### 2.3 Wire real execution into block views

- User types a natural language ask in the input bar
- AI engine returns a plan with commands
- Each command executes via `ShellBridge`
- Output feeds into `CommandExecution.output` as `NSAttributedString`
- Views update reactively via `@Published` properties

**Success criteria for Phase 2:** Type "list files in /tmp" in input
bar. AI generates `ls /tmp`. Command executes. Output appears in a
collapsible block with real ANSI colors. Exit code shows green/red.

## Phase 3: LLM Integration (days 6-7)

### 3.1 AI engine

Port the existing `Engine.zig` logic to Swift, calling llama.cpp via
its C API. Or use an HTTP API (Ollama, OpenAI) for simpler integration.

The engine needs to:
1. Accept a natural language prompt + context (pwd, recent commands)
2. Stream a response that may contain `<think>` blocks and command
   blocks (fenced with triple backticks or a structured format)
3. Parse the response into `AIResponse` with segments

### 3.2 Streaming UI

As the LLM streams tokens:
- `ThinkingBlock` appears with a spinner, then shows duration on close
- Text segments appear word by word
- Command segments appear and auto-execute when complete
- Credits counter increments

### 3.3 Multi-turn conversation

The block list IS the conversation. Each user ask and AI response is a
block. The session maintains conversation history for the LLM context
window.

**Success criteria for Phase 3:** Full conversation loop. Ask a
question, see thinking, see commands execute, see results, ask a
follow-up. Credits track token usage.

## Phase 4: Live Terminal Integration (days 8-9)

### 4.1 Ghostty SurfaceView at the bottom

The live terminal sits below the block list. It runs an interactive
shell session. When the user types a raw command (not an AI ask) in the
input bar, it goes to the PTY.

### 4.2 Command-to-block promotion

When a command finishes in the live terminal (detected via
`COMMAND_FINISHED` callback):
1. Extract the command text and output via `ghostty_surface_read_text`
2. Create a `CommandResult` block
3. Append to the block list above the live terminal
4. Clear the completed output from the live terminal viewport
   (or scroll it up naturally)

This is optional for the PoC — the AI-executed commands already appear
as blocks. The live terminal is a fallback for interactive use.

### 4.3 Full-screen program handling

When the user runs vim, ssh, top, etc.:
- Detect alternate screen activation
- Hide the block list and input bar
- Expand the Ghostty SurfaceView to fill the window
- On alternate screen exit, restore the block layout

**Success criteria for Phase 4:** Full app with AI blocks above, live
terminal below, input bar at bottom. Interactive programs work.

## Phase 5: Polish (days 10+)

- Keyboard shortcuts (Cmd+K for AI input, Cmd+L to clear, arrows to
  navigate blocks)
- Block selection and copy (Cmd+C copies the focused block's content)
- Search across blocks
- Syntax highlighting in command output (beyond ANSI)
- Block re-run (click to re-execute a command)
- Export conversation to markdown
- Settings UI (model selection, API keys, theme)

## Why This Approach Solves the Problems We Had

| Problem with overlay approach | How native SwiftUI solves it |
|-------------------------------|------------------------------|
| Can't collapse terminal rows | `DisclosureGroup` / `isExpanded` toggle |
| Can't mix fonts (mono + proportional) | Different `Font` per view |
| Can't render rich text / markdown | SwiftUI `Text` with `AttributedString` |
| Can't add interactive buttons | Standard SwiftUI `Button` |
| z2d overlay is CPU-rendered | SwiftUI uses Core Animation (GPU) |
| Hit zone tracking for buttons | Native gesture recognizers |
| Terminal grid limits layout | `VStack` / `LazyVStack`, any layout |
| No variable-height regions | SwiftUI auto-sizes views to content |

## Technical Risks and Mitigations

### Risk: GhosttyKit framework extraction is fragile

**Mitigation:** Phase 0 validates this immediately. If embedding
GhosttyKit is too complex, fall back to a simpler PTY + ANSI parser
approach for the live terminal (use a `TerminalView` from an open
source Swift terminal library like SwiftTerm).

### Risk: ANSI-to-AttributedString loses fidelity

**Mitigation:** Use Ghostty's own formatter API (`FORMAT_HTML`) to get
accurate rendering. Parse the HTML into `NSAttributedString` via
`NSAttributedString(html:)`.

### Risk: AI command execution is unsafe

**Mitigation:** Show each command before execution. Require explicit
user approval (click or Enter) before running. Display a warning for
destructive commands (rm, sudo).

### Risk: Block list performance with many blocks

**Mitigation:** Use `LazyVStack` for virtualized rendering. Collapsed
blocks are lightweight (one line of text). Only expanded blocks render
full output.

## File/Effort Estimates

| Phase | Files | New Lines | Effort |
|-------|-------|-----------|--------|
| 0: Scaffold | 5 | ~200 | 1 day |
| 1: Static UI | 8 | ~600 | 2 days |
| 2: ANSI + exec | 3 | ~400 | 2 days |
| 3: LLM | 2 | ~300 | 2 days |
| 4: Terminal | 2 | ~200 | 2 days |
| 5: Polish | — | ~400 | ongoing |
| **Total** | **~20** | **~2100** | **~9 days** |
