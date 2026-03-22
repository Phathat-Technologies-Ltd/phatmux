# Panes and Surfaces

Split layout, surface creation, focus, move, and reorder.

## Inspect

```bash
phatmux list-panes
phatmux list-pane-surfaces --pane pane:1
```

## Create Splits/Surfaces

```bash
phatmux new-split right --panel pane:1
phatmux new-surface --type terminal --pane pane:1
phatmux new-surface --type browser --pane pane:1 --url https://example.com
```

## Focus and Close

```bash
phatmux focus-pane --pane pane:2
phatmux focus-panel --panel surface:7
phatmux close-surface --surface surface:7
```

## Move/Reorder Surfaces

```bash
phatmux move-surface --surface surface:7 --pane pane:2 --focus true
phatmux move-surface --surface surface:7 --workspace workspace:2 --window window:1 --after surface:4
phatmux reorder-surface --surface surface:7 --before surface:3
```

Surface identity is stable across move/reorder operations.
