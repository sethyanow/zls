---
id: zls-81s
title: 'workspaceSymbol: return all declarations on empty query'
status: open
type: bug
priority: 2
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
            // Skip sort — we'll sort the final result alphabetically
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

- [ ] `workspace/symbol` with empty query returns all indexed declarations sorted alphabetically
- [ ] `workspace/symbol` with non-empty query continues to use trigram matching (no regression)
- [ ] Existing workspace_symbols tests pass
- [ ] `zig build test --summary all` passes
- [ ] `zig fmt --check .` passes

## Anti-Patterns

- DO NOT add a result cap — YAGNI. Clients paginate if needed. Add a cap later if real-world usage shows it's needed.
- DO NOT change the trigram-query path — the fix is additive (empty-query branch), not a rewrite.
- DO NOT sort the trigram-query results alphabetically — relevance-ranked results from trigram matching should stay in their existing order (by token index within each file).

## Implementation

1. Write a regression test: send `workspace/symbol` with empty query, assert non-null result with declarations from the test document.
2. Write a test: send `workspace/symbol` with non-empty query, assert existing behavior unchanged.
3. Modify `handler` in `workspace_symbols.zig`: remove the `if (request.query.len == 0) return null` guard, add the empty-query enumeration path, add alphabetical sort for empty-query results.
4. Run tests, verify both empty and non-empty queries work.
5. Run full suite, format check.
