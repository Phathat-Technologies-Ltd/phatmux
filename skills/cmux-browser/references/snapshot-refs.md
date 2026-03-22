# Snapshot and Refs

Element refs from snapshots make browser automation compact and reliable.

**Related**: [commands.md](commands.md), [SKILL.md](../SKILL.md)

## Contents

- [How Refs Work](#how-refs-work)
- [The Snapshot Command](#the-snapshot-command)
- [Using Refs](#using-refs)
- [Ref Lifecycle](#ref-lifecycle)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## How Refs Work

Classic flow:

```text
full DOM/HTML -> selector guessing -> action
```

phatmux flow:

```text
snapshot -> refs (e1/e2/...) -> direct action
```

## The Snapshot Command

```bash
phatmux browser surface:7 snapshot
phatmux browser surface:7 snapshot --interactive
phatmux browser surface:7 snapshot --interactive --compact --max-depth 3
```

## Using Refs

```bash
phatmux browser surface:7 click e6
phatmux browser surface:7 fill e10 "user@example.com"
phatmux browser surface:7 fill e11 "password123"
phatmux browser surface:7 click e12
```

## Ref Lifecycle

Refs are invalidated when page structure changes.

```bash
phatmux browser surface:7 snapshot --interactive
# e1 is "Next"

phatmux browser surface:7 click e1

# page changed, take a fresh snapshot
phatmux browser surface:7 snapshot --interactive
```

## Best Practices

1. Snapshot before interacting.
2. Re-snapshot after navigation/modal/open-close flows.
3. Use `--snapshot-after` on mutating actions.
4. Scope snapshots with `--selector` for very large pages.

## Troubleshooting

### not_found / stale ref

```bash
phatmux browser surface:7 snapshot --interactive
```

### Element missing due visibility/timing

```bash
phatmux browser surface:7 wait --selector "#target" --timeout-ms 10000
phatmux browser surface:7 scroll --dy 400
phatmux browser surface:7 snapshot --interactive
```

### Too many elements

```bash
phatmux browser surface:7 snapshot --selector "form#checkout" --interactive
```
