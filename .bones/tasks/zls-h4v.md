---
id: zls-h4v
title: 'Phase 1: Cross-File Reference Coverage Fix'
status: open
type: epic
priority: 1
depends_on: [zls-91m]
parent: zls-xjj
---



## Context
Parent epic zls-xjj, Phase 1. No prior phase dependency.

ZLS's `findReferences` has incomplete cross-file coverage. Testing showed it finds 2 of 5 files for `resolveTypeOfNode` and 6 of 14 files for `offsets.Loc`. The root cause: `DocumentStore` only searches files already loaded in memory. The build-system path in `gatherWorkspaceReferenceCandidates` follows `file_imports` from the root source file, but the fallback path (used when no build system is configured, which is the Claude Code LSP scenario) only iterates handles already in the store.

This phase fixes the foundation so Phase 2 (call hierarchy) builds on reliable cross-file infrastructure.

## Requirements
- R5: DocumentStore shall eagerly load files transitively reachable via `@import` chains when a file is opened. No artificial bound on depth or file count.
- R6: `gatherWorkspaceReferenceCandidates` shall load files on-demand during reference search as a fallback.
- R7: `findReferences` cross-file coverage shall improve without changes to the references handler itself.

## Success Criteria
- [x] When a file is opened in DocumentStore, all files reachable via `@import` chains are transitively loaded
- [x] `gatherWorkspaceReferenceCandidates` loads unresolved imports on-demand as fallback
- [ ] `findReferences` returns results across all transitively imported files (not just already-opened files)
- [x] `zig build test --summary all` passes
- [x] `zig build check` compiles clean
- [x] `zig fmt --check .` passes
- [ ] Live LSP demo: `findReferences` on `resolveTypeOfNode` finds callers in 5+ feature files

## Anti-Patterns
- NO fixing only the build-system path (R5 requires eager loading regardless of build system. Claude Code doesn't configure workspaces.)
- NO on-demand-only approach (can't discover files that import the target in the reverse direction without eager forward loading)
- NO artificial bounds on transitive loading (the import graph IS the compilation unit)
- NO changes to the references handler itself (R7: the fix is in DocumentStore and gatherWorkspaceReferenceCandidates, references benefits automatically)

## Key Considerations
- `file_imports` on a Handle contains URIs of all `@import`ed files. Following these transitively is the mechanism.
- `getOrLoadHandle` already handles loading from disk for `file://` URIs. For `untitled://` URIs it just does a lookup.
- The `HandleIterator` iterates `store.handles` — once eager loading populates this, the fallback path in `gatherWorkspaceReferenceCandidates` automatically benefits.
- Must not cause infinite loops if there are circular imports (Zig doesn't allow them, but defensive coding).
- Performance: loading the full import graph happens once per file open, amortized. Zig projects have bounded import graphs.

## Acceptance Requirements
**Agent Documentation:** Update stale docs only.
- [ ] CLAUDE.md: none expected (no new commands or config)
- [ ] Project docs: none expected

**User Demo:** Live narrated LSP tool walkthrough.
- Run `findReferences` on `resolveTypeOfNode` (analysis.zig:1943) — show results now include references.zig, semantic_tokens.zig, inlay_hints.zig (previously missed)
- Run `findReferences` on `getPositionContext` (analysis.zig:5355) — show it now finds references.zig and code_actions.zig (previously missed)
- Explain each LSP call as it happens: what's being queried, what the result means, how many files were found vs the prior baseline
- Show at least one case where a file that was previously missed is now found
