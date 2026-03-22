# Command Reference (phatmux Browser)

This maps common `agent-browser` usage to `phatmux browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `phatmux browser open <url>`
- `agent-browser goto|navigate <url>` -> `phatmux browser <surface> goto|navigate <url>`
- `agent-browser snapshot -i` -> `phatmux browser <surface> snapshot --interactive`
- `agent-browser click <ref>` -> `phatmux browser <surface> click <ref>`
- `agent-browser fill <ref> <text>` -> `phatmux browser <surface> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `phatmux browser <surface> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `phatmux browser <surface> select <ref> <value>`
- `agent-browser get text <ref>` -> `phatmux browser <surface> get text <ref-or-selector>`
- `agent-browser get url` -> `phatmux browser <surface> get url`
- `agent-browser get title` -> `phatmux browser <surface> get title`

## Core Command Groups

### Navigation

```bash
phatmux browser open <url>                        # opens in caller's workspace (uses PHATMUX_WORKSPACE_ID)
phatmux browser open <url> --workspace <id|ref>   # opens in a specific workspace
phatmux browser <surface> goto <url>
phatmux browser <surface> back|forward|reload
phatmux browser <surface> get url|title
```

> **Workspace context:** `browser open` targets the workspace of the terminal where the command is run (via `PHATMUX_WORKSPACE_ID`), even if a different workspace is currently focused. Use `--workspace` to override.

### Snapshot and Inspection

```bash
phatmux browser <surface> snapshot --interactive
phatmux browser <surface> snapshot --interactive --compact --max-depth 3
phatmux browser <surface> get text body
phatmux browser <surface> get html body
phatmux browser <surface> get value "#email"
phatmux browser <surface> get attr "#email" --attr placeholder
phatmux browser <surface> get count ".row"
phatmux browser <surface> get box "#submit"
phatmux browser <surface> get styles "#submit" --property color
phatmux browser <surface> eval '<js>'
```

### Interaction

```bash
phatmux browser <surface> click|dblclick|hover|focus <selector-or-ref>
phatmux browser <surface> fill <selector-or-ref> [text]   # empty text clears
phatmux browser <surface> type <selector-or-ref> <text>
phatmux browser <surface> press|keydown|keyup <key>
phatmux browser <surface> select <selector-or-ref> <value>
phatmux browser <surface> check|uncheck <selector-or-ref>
phatmux browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Wait

```bash
phatmux browser <surface> wait --selector "#ready" --timeout-ms 10000
phatmux browser <surface> wait --text "Done" --timeout-ms 10000
phatmux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
phatmux browser <surface> wait --load-state complete --timeout-ms 15000
phatmux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
phatmux browser <surface> cookies get|set|clear ...
phatmux browser <surface> storage local|session get|set|clear ...
phatmux browser <surface> tab list|new|switch|close ...
phatmux browser <surface> state save|load <path>
```

### Diagnostics

```bash
phatmux browser <surface> console list|clear
phatmux browser <surface> errors list|clear
phatmux browser <surface> highlight <selector>
phatmux browser <surface> screenshot
phatmux browser <surface> download wait --timeout-ms 10000
```

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- Use `--id-format both` only when a UUID must be logged/exported.

## Known WKWebView Gaps (`not_supported`)

- `browser.viewport.set`
- `browser.geolocation.set`
- `browser.offline.set`
- `browser.trace.start|stop`
- `browser.network.route|unroute|requests`
- `browser.screencast.start|stop`
- `browser.input_mouse|input_keyboard|input_touch`

See also:
- [snapshot-refs.md](snapshot-refs.md)
- [authentication.md](authentication.md)
- [session-management.md](session-management.md)
