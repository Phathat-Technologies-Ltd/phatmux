# Windows and Workspaces

Window/workspace lifecycle and ordering operations.

## Inspect

```bash
phatmux list-windows
phatmux current-window
phatmux list-workspaces
phatmux current-workspace
```

## Create/Focus/Close

```bash
phatmux new-window
phatmux focus-window --window window:2
phatmux close-window --window window:2

phatmux new-workspace
phatmux select-workspace --workspace workspace:4
phatmux close-workspace --workspace workspace:4
```

## Reorder and Move

```bash
phatmux reorder-workspace --workspace workspace:4 --before workspace:2
phatmux move-workspace-to-window --workspace workspace:4 --window window:1
```
