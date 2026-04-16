---
id: zls-81s
title: 'workspaceSymbol: return all declarations on empty query'
status: closed
type: bug
priority: 2
owner: Seth
---





## Context

`workspace/symbol` with an empty query returns `null` in ZLS (`src/features/workspace_symbols.zig:15`). The LSP spec allows servers to return all symbols or a useful subset when the query is empty. rust-analyzer returns up to 128 symbols alphabetically. Other language servers (pyright, typescript-language-server) also return results on empty query.

AI coding agents (Claude Code, Cursor, etc.) use `workspaceSymbol` as a discovery tool — "show me what's in this project." The Claude Code LSP tool currently sends an empty query string (no query parameter exposed). With ZLS returning null, agents get nothing and fall back to slower file-by-file exploration.

The fix is in one file: `src/features/workspace_symbols.zig`. The TrigramStore already indexes all declarations — the empty-query path just needs to iterate them directly instead of going through trigram matching.

## Requirements

- R1: `workspace/symbol` with an empty query (`request.query.len == 0`) shall return all indexed declarations across all workspace trigram stores, sorted alphabetically by name.
- R2: Non-empty queries continue to use trigram matching (existing behavior unchanged).

## Design Direction

Remove the early return on line 15. When `query.len == 0`, iterate all declarations from each trigram store's `declarations` multi-array list directly (skip `declarationsForQuery`). The rest of the pipeline — name resolution via `tokenNameMaybeQuotes`, kind mapping, position calculation — stays identical.

### Empty-query path

For each handle's trigram store, iterate `0..trigram_store.declarations.len` to get all declaration indices. Feed these into the same symbol-building loop that the trigram-query path uses.

### Sorting

The existing code sorts by token index (source order within a file). For the empty-query path, sort the final result alphabetically by `symbol.name` across all files. This matches rust-analyzer's behavior and makes the output useful for discovery.

For non-empty queries, keep the existing sort (by token index within each file) — relevance-ranked results shouldn't be re-sorted alphabetically.

### Sketch

```zig
pub fn handler(...) ... {
    // ... workspace URIs, load trigram stores (unchanged) ...

    for (handles) |handle| {
        const trigram_store = handle.trigram_store.getCached();

        if (request.query.len > 0) {
            // Existing trigram-query path (unchanged)
            declaration_buffer.clearRetainingCapacity();
            try trigram_store.declarationsForQuery(arena, request.query, &declaration_buffer);
            // ... existing sort by token index ...
        } else {
            // Empty-query: enumerate all declarations
            declaration_buffer.clearRetainingCapacity();
            try declaration_buffer.ensureUnusedCapacity(arena, trigram_store.declarations.len);
            for (0..trigram_store.declarations.len) |i| {
                declaration_buffer.appendAssumeCapacity(@enumFromInt(i));
            }
            // MUST still sort by token index for correct advancePosition calculation
        }

        // ... existing symbol-building loop (unchanged) ...
    }

    // For empty query, sort final results alphabetically
    if (request.query.len == 0) {
        std.mem.sortUnstable(types.workspace.Symbol, symbols.items, {}, struct {
            fn lessThan(_: void, a: types.workspace.Symbol, b: types.workspace.Symbol) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
    }

    return .{ .workspace_symbols = symbols.items };
}
```

### Types

- `TrigramStore.declarations`: `std.MultiArrayList(Declaration)` — `.len` gives total count
- `Declaration.Index`: `enum(u32)` — cast from iteration index via `@enumFromInt(i)`
- `types.workspace.Symbol`: has `.name: []const u8`, `.kind: SymbolKind`, `.location: Location`
- `declaration_buffer`: `std.ArrayList(TrigramStore.Declaration.Index)` — reused per handle

## Success Criteria

- [x] `workspace/symbol` with empty query returns all indexed declarations sorted alphabetically
- [x] `workspace/symbol` with non-empty query continues to use trigram matching (no regression)
- [x] Existing workspace_symbols tests pass
- [x] `zig build test --summary all` passes
- [x] `zig fmt --check .` passes

## Anti-Patterns

- DO NOT add a result cap — YAGNI. Clients paginate if needed. Add a cap later if real-world usage shows it's needed.
- DO NOT change the trigram-query path — the fix is additive (empty-query branch), not a rewrite.
- DO NOT sort the trigram-query results alphabetically — relevance-ranked results from trigram matching should stay in their existing order (by token index within each file).

## Key Considerations

**Test infrastructure: trigram store availability**
- SRE VERIFIED: `addWorkspace("Animal Shelter", "/animal_shelter/")` registers workspace URI `untitled:/animal_shelter/`. `addDocument` with `base_directory: "/animal_shelter/"` creates URIs like `untitled:///animal_shelter/Untitled-0.zig`. `loadTrigramStores` filters by `startsWith` on path — this matches. Trigram stores are lazily populated via `handle.trigram_store.get(handle)`. The existing workspace_symbols tests confirm this infra works. No fixture changes needed.

**CRITICAL: Per-file token-index sort is required even on empty-query path**
- The symbol-building loop (lines 54-66 in current code) uses `advancePosition` with `last_index`/`last_position` to incrementally compute LSP positions. This requires declarations to be processed in monotonically increasing byte offset order within each file. The sketch comment "Skip sort — we'll sort the final result alphabetically" is WRONG for the per-handle loop — skipping the per-file token-index sort produces incorrect LSP positions. CORRECT approach: sort declaration_buffer by token index within each handle (same as existing code), build symbols, THEN sort the final symbols array alphabetically after the handles loop.

**Adversarial Catalog**

**Resource Exhaustion: Declaration enumeration**
- Assumption: Workspace has a reasonable number of declarations
- Betrayal: Massive workspace (thousands of files, hundreds of declarations each) — empty query returns ALL of them. No trigram intersection to naturally limit results.
- Consequence: Large response, high memory use (arena-allocated, freed after handler returns)
- Mitigation: By design — anti-pattern explicitly forbids a result cap. Arena per-request means no persistent leak. Clients handle large result sets via their own pagination/truncation. Same resource profile as `documentSymbol` on a large file.

**Input Hostility: Alphabetical sort with special characters**
- Assumption: `std.mem.order(u8, ...)` produces useful sort for symbol names
- Betrayal: Zig `@"..."` identifiers sort by raw bytes — `@` (0x40) sorts before uppercase letters (0x41+), which sort before lowercase (0x61+). Not locale-aware.
- Consequence: Grouping is `@`-prefixed → UPPER → lower. Consistent but potentially surprising to clients expecting case-insensitive sort.
- Mitigation: Acceptable — matches rust-analyzer's behavior (byte-order sort). LSP spec doesn't mandate sort order. Byte-order is deterministic and fast. Case-insensitive sort would be a design decision, not a bug fix.

**Temporal Betrayal: Declaration enumeration vs getCached()**
- Assumption: `getCached()` returns a fully populated trigram store
- Betrayal: Could `getCached()` return a store mid-population?
- Mitigation: `loadTrigramStores` calls `handle.trigram_store.get(handle)` synchronously (with group.await) before returning handles. By the time handler iterates, all stores are fully populated. No race.

## Implementation

1. Write a regression test: send `workspace/symbol` with empty query, assert non-null result with declarations from the test document.
2. Write a test: send `workspace/symbol` with non-empty query, assert existing behavior unchanged.
3. Modify `handler` in `workspace_symbols.zig`: remove the `if (request.query.len == 0) return null` guard, add the empty-query enumeration path, add alphabetical sort for empty-query results.
4. Run tests, verify both empty and non-empty queries work.
5. Run full suite, format check.

## Log

- [2026-04-16T14:30:29Z] [Seth] SRE + adversarial complete. Key finding: sketch had a bug — empty-query path MUST still sort declaration_buffer by token index per-handle for correct advancePosition calculation. Verified test infra works (addWorkspace + addDocument with base_directory populates trigram stores). Adversarial: no new success criteria needed — resource exhaustion is by-design (no cap), sort order is byte-order (matches rust-analyzer).
- [2026-04-16T14:37:48Z] [Seth] Closed. Implementation: +17 lines in handler (empty-query enumeration + alphabetical sort), +99 lines in tests (4 new test cases: full fixture, empty workspace, single declaration, duplicate names). All 5 success criteria met. SRE caught critical bug in sketch (position calculation requires per-file token-index sort even on empty-query path). Adversarial stress test: 3 patterns tested, all GREEN.
