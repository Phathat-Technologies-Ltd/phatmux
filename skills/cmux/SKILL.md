---
name: phatmux
description: End-user control of phatmux topology and routing (windows, workspaces, panes/surfaces, focus, moves, reorder, identify, trigger flash). Use when automation needs deterministic placement and navigation in a multi-pane phatmux layout.
---

# phatmux Core Control

Use this skill to control non-browser phatmux topology and routing.

## Core Concepts

- Window: top-level macOS phatmux window.
- Workspace: tab-like group within a window.
- Pane: split container in a workspace.
- Surface: a tab within a pane (terminal or browser panel).

## Fast Start

```bash
# identify current caller context
phatmux identify --json

# list topology
phatmux list-windows
phatmux list-workspaces
phatmux list-panes
phatmux list-pane-surfaces --pane pane:1

# create/focus/move
phatmux new-workspace
phatmux new-split right --panel pane:1
phatmux move-surface --surface surface:7 --pane pane:2 --focus true
phatmux reorder-surface --surface surface:7 --before surface:3

# attention cue
phatmux trigger-flash --surface surface:7
```

## Handle Model

- Default output uses short refs: `window:N`, `workspace:N`, `pane:N`, `surface:N`.
- UUIDs are still accepted as inputs.
- Request UUID output only when needed: `--id-format uuids|both`.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Handle syntax, self-identify, caller targeting |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window/workspace lifecycle and reorder/move |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, surfaces, move/reorder, focus routing |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue and surface health checks |
| [../phatmux-browser/SKILL.md](../phatmux-browser/SKILL.md) | Browser automation on surface-backed webviews |
| [../phatmux-markdown/SKILL.md](../phatmux-markdown/SKILL.md) | Markdown viewer panel with live file watching |
