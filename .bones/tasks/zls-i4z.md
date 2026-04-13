---
id: zls-i4z
title: 'Phase 1 Acceptance: Cross-File Reference Coverage Live Demo'
status: closed
type: task
priority: 1
parent: zls-h4v
---





## Context

Phase 1 of zls-xjj (Cross-File Reference Coverage Fix) is technically complete after zls-91m. All technical criteria are met: R5 eager loading, R6 on-demand fallback, ensureHandleLoaded API for deadlock safety, R5/R6 tests passing, full test suite passing, format check clean. This task is the user-facing acceptance step.

## Agent Documentation

No documentation updates expected for this phase (no new commands, no new config, no user-visible API changes). The implementation is internal to DocumentStore and the references feature.

## User Demo

Live narrated LSP tool walkthrough demonstrating that cross-file references now find more callers than before the fix.

**Demo 1: `resolveTypeOfNode`**
- Run `findReferences` on `resolveTypeOfNode` defined in `src/analysis.zig`
- Expected: results now include callers in `references.zig`, `semantic_tokens.zig`, `inlay_hints.zig`, `completions.zig`, `hover.zig` — files that were previously missed
- Narrate: "Querying findReferences on `resolveTypeOfNode`. Before this fix, ZLS found 2 of 5 caller files. After eager transitive import loading, the result includes [N] files."

**Demo 2: `getPositionContext`**
- Run `findReferences` on `getPositionContext` defined in `src/analysis.zig`
- Expected: results now include `references.zig`, `code_actions.zig` — previously missed
- Narrate: "Querying findReferences on `getPositionContext`. Before, the fallback path only saw files explicitly opened in the editor. Now, opening any file transitively loads its import graph, so the reverse dependency walk has more handles to draw from."

**Demo 3 (optional): Show a previously-missed file**
- Pick one specific (file, function) pair where the result was missed before and is now found
- Demonstrate the result includes the new file

**What success looks like:** Each LSP call returns more cross-file results than the documented baseline (2/5 and 6/14). The user should be able to see the difference and confirm the fix is real.

## Success Criteria

- [x] Demo 1: `findReferences` on `resolveTypeOfNode` finds 5+ caller files
- [x] Demo 2: `findReferences` on `getPositionContext` finds references in code_actions.zig and references.zig
- [x] Each LSP call narrated with what it does and what the result means
- [x] User accepts the demo

## Log

- [2026-04-13T13:07:49Z] [Seth] Live demo executed via LSP tool. Demo 1 (resolveTypeOfNode analysis.zig:1943): 37 refs across 5 files — analysis.zig, completions.zig, inlay_hints.zig, references.zig, semantic_tokens.zig. First call returned only analysis.zig internal refs because build-file resolution was async; retry after resolution gave full result — this matches references.zig:337 'should await instead' comment (known pre-existing limitation outside Phase 1 scope). Demo 2 (getPositionContext analysis.zig:5355): 7 refs across 6 files including both required targets code_actions.zig:95 and references.zig:702. Both acceptance criteria met. User accepted.
