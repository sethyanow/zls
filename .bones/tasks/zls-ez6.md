---
id: zls-ez6
title: gatherWorkspaceReferenceCandidates build-system path drops loaded handles not in module graph
status: active
type: bug
priority: 1
owner: Seth
parent: zls-gyi
---






## Context

`gatherWorkspaceReferenceCandidates` (`src/features/references.zig:330`) has two paths:

1. **Build-system path** (line 338-403): seeds from module roots in `BuildConfig`, walks forward via `file_imports` + `resolved_imports`.
2. **Fallback path** (line 406+): iterates ALL loaded handles via `HandleIterator`, builds reverse dependency map.

These paths are **mutually exclusive** — if the build config resolves, only the build-system path runs. This means files that are loaded in the DocumentStore but NOT reachable from any module root in `build.zig` are silently dropped from the candidate set.

## Reproduction

Using `tests/fixtures/module_imports/`:
- `a.zig` — module root (`mod_a`), imports `@import("mod_b")`
- `b.zig` — module root (`mod_b`), defines `doubled()`
- `c.zig` — NOT a module root, imports `@import("b.zig")`, calls `doubled()`

Query: `incomingCalls` on `doubled` in `b.zig`.

1. **First query** (build runner still running, config not ready): falls through to fallback path → finds `c.zig:wrap` as caller. Correct.
2. **Second query** (build config resolved): uses build-system path, seeds from module roots `a.zig` and `b.zig` → finds `a.zig:entry` but NOT `c.zig:wrap`. `c.zig` is loaded but unreachable from module roots.

Result: having a build config produces FEWER results than not having one. The build-system path should be a superset of the fallback, not a replacement.

## Requirements

- R1: When the build-system path resolves, its candidate set must include all handles that the fallback path would have found — the build-system path must be a superset, not a replacement.
- R2: No regression in existing findReferences, incomingCalls, or outgoingCalls behavior for files that ARE module roots.

## Success Criteria

- [ ] `incomingCalls` on `doubled` in `b.zig` returns BOTH `a.zig:entry` (module-name import) and `c.zig:wrap` (file-path import) when the build config is resolved
- [ ] Existing references.zig and call_hierarchy.zig tests pass (`zig build test --summary all`)
- [ ] Union loop filters std URIs via `DocumentStore.isInStd` — consistent with the build-system forward walk's std filtering

## Anti-Patterns

- DO NOT remove the build-system forward walk — module-root seeding discovers unloaded files that `HandleIterator` wouldn't see. The union must preserve both strategies.
- DO NOT modify the fallback path (line 406+) — it's correct as-is. The fix is in the build-system path only.
- DO NOT make `c.zig` a module root in the test config — that sidesteps the bug. The test must reproduce the real scenario: c.zig is loaded but not a module root.

## Design Direction

Union the two strategies instead of choosing one. After the build-system forward walk completes (line 402), also iterate loaded handles via `HandleIterator` and add any that aren't already in `found_uris`. This preserves the build-system path's module-root seeding (which discovers unloaded files) while also including loaded files that aren't part of the module graph.

The union loop must filter std URIs via `isInStd` — the build-system forward walk already skips std (line 399), and the fallback path doesn't include std because it only builds reverse deps. Without filtering, the union would add std to the candidate set, ballooning it (every file imports std).

Sketch — insert between line 402 and the existing `return found_uris` at line 403:
```zig
// Union with loaded handles so files open in the editor but not
// in the module graph are still searched.
var it: DocumentStore.HandleIterator = .{ .store = store };
while (it.next()) |handle| {
    if (DocumentStore.isInStd(handle.uri)) continue;
    try found_uris.put(arena, handle.uri, {});
}
return found_uris;
```

`found_uris.put` is idempotent — handles already discovered by the forward walk are silently deduplicated.

## Key Considerations

### HandleIterator union loop

**Input Hostility: std pollution in union**
- Assumption: Loaded handles are all user-code files
- Betrayal: Eager transitive import loading loads std if any file imports `std`. `HandleIterator` iterates ALL loaded handles including std.
- Consequence: Without `isInStd` filtering, the candidate set includes std source files — slow, noisy, false-positive results.
- Mitigation: Union loop filters via `DocumentStore.isInStd(handle.uri)`, matching the build-system forward walk's filter at line 399.

### Regression test

**Temporal Betrayal: Test cache warming**
- Assumption: The test exercises the build-system forward walk's `resolved_imports` edge
- Betrayal: If `uriFromImportStr` isn't called to warm `a_handle.resolved_imports` before the query, `a.zig` appears only because it was seeded as a module root, not because the module-name import was resolved.
- Consequence: Test passes vacuously — doesn't catch regressions where `resolved_imports` walking breaks.
- Mitigation: Test must call `uriFromImportStr(a_handle, "mod_b")` before the query. Assert both `a.zig` (proves module-name resolution) AND `c.zig` (proves union) appear.

**Input Hostility: Test config shape**
- Assumption: Two-module config reproduces the bug
- Betrayal: If c.zig is accidentally a module root in the config, the build-system forward walk discovers it via seeding — test passes without the union fix.
- Consequence: False green — test doesn't verify the fix.
- Mitigation: Config must have exactly two modules (a_path, b_path). Stamp only `a_handle` and `b_handle`. `c_handle` stays at `.init`/`.none` — no associated build file.

## Implementation

1. Write a regression test in `tests/lsp_features/references.zig` that reproduces the bug: open all three fixture files (`a.zig`, `b.zig`, `c.zig`), stamp `a.zig` and `b.zig` as resolved module roots (but NOT `c.zig`), warm resolution caches, run `incomingCalls` on `doubled` in `b.zig`, assert both `a.zig` and `c.zig` appear as callers. Use the existing `helper_build.makeResolved`/`stampResolved` pattern from the zls-029 tests (line ~2040), but with a two-module config (mod_a, mod_b only — no mod_c).
2. Run the test — confirm it fails (c.zig missing from results because the build-system path returns before reaching the fallback).
3. Insert the `HandleIterator` union loop at `src/features/references.zig:402` (between the forward walk's closing brace and the `return found_uris`). Filter std URIs.
4. Run the test — confirm it passes (c.zig now included via HandleIterator union).
5. Run full test suite (`zig build test --summary all`) — confirm no regressions.
6. Run `zig fmt --check .` — confirm clean formatting.

## Log

- [2026-04-16T06:40:00Z] [Seth] Filed from acceptance demo. Build-system candidate path (references.zig:338-403) replaces the fallback HandleIterator path instead of unioning with it. Fix: after build-system forward walk, also iterate loaded handles so open files outside the module graph are still searched.
