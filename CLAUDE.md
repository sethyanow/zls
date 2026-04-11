# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is ZLS

ZLS is the Zig Language Server -- an LSP implementation for Zig, written in Zig. It tracks Zig master (nightly). The default branch is `master`.

## Build and Test Commands

Requires Zig nightly matching the `minimum_zig_version` in `build.zig.zon`.

```bash
zig build                              # Build ZLS executable
zig build -Doptimize=ReleaseSafe       # Optimized build
zig build check                        # Type-check only (fast, no codegen)
zig build test --summary all           # Run ALL tests (unit + analysis + build runner)
zig build test -Dtest-filter="name"    # Run tests matching filter
zig build test-analysis                # Run only analysis test cases (tests/analysis/*.zig)
zig build test-build-runner            # Run only build runner test cases
zig fmt --check .                      # Check formatting (CI enforces this)
zig fmt src/file.zig                   # Format a file
```

## Test Architecture

There are four test categories, all triggered by `zig build test`:

1. **Unit tests** (`src/zls.zig` via `refAllDecls`) -- standard `test` blocks in src/ files, run via `zig build test` as the "src test" artifact.
2. **LSP feature tests** (`tests/tests.zig`) -- test LSP protocol features (completion, hover, goto, etc.) by spinning up a `zls.Server` in-process via `tests/context.zig`. Each test file in `tests/lsp_features/` corresponds to a feature in `src/features/`.
3. **Analysis tests** (`tests/analysis/*.zig`) -- standalone `.zig` files compiled into a separate `analysis_check` executable that validates the analyser. Added to the build via `tests/add_analysis_cases.zig`.
4. **Build runner tests** (`tests/build_runner_cases/`) -- pairs of `.zig` + `.json` files. Runs the ZLS build runner against a `build.zig` and diffs output against expected JSON. Added via `tests/add_build_runner_cases.zig`.

The test context (`tests/context.zig`) creates a `zls.Server`, sends `initialize`/`initialized` LSP messages, and provides `addDocument` for feeding source code. Tests use `tests/helper.zig` for placeholder manipulation (`<placeholder>` markers in source strings).

## Architecture Overview

### Request Flow

`src/main.zig` (CLI entry, logging, config path resolution) -> `src/Server.zig` (LSP main loop, request dispatch, global state) -> `src/features/*.zig` (individual LSP method handlers).

### Core Components

- **`Server.zig`** -- the heart of ZLS. Owns the main loop, job scheduling, LSP transport, and dispatches requests to feature handlers. Holds global state including `DocumentStore`, `InternPool`, and `DiagnosticsCollection`.
- **`DocumentStore.zig`** -- thread-safe container for all open documents. Manages source files, build files, and interfaces with the build system. Uses `DocumentScope` for per-file scope/symbol information.
- **`analysis.zig` (Analyser)** -- the analysis backend. Key functions: `resolveTypeOfNode`, `getPositionContext`, `lookupSymbolGlobal`, `lookupSymbolContainer`. Instantiated per-request from Server, uses the shared `InternPool`.
- **`analyser/InternPool.zig`** -- type interning pool based on the Zig compiler's `InternPool`. Stores types, declarations, structs, enums, unions. Shared across analysis operations.
- **`DocumentScope.zig`** -- per-document scope analysis. Builds scope trees and declarations from AST.
- **`configuration.zig`** -- config resolution with a `Manager` that merges settings from multiple sources (CLI, LSP client, `zls.json`).
- **`offsets.zig`** -- position/offset conversion utilities between byte offsets, LSP positions, and encoding types (UTF-8/UTF-16/UTF-32).

### Feature Modules (`src/features/`)

Each file implements one or more LSP methods: `completions.zig`, `goto.zig`, `hover.zig`, `references.zig`, `semantic_tokens.zig`, `code_actions.zig`, `inlay_hints.zig`, `diagnostics.zig`, `folding_range.zig`, `document_symbol.zig`, `selection_range.zig`, `signature_help.zig`.

### Build Runner (`src/build_runner/`)

A custom build runner that ZLS injects into the user's `zig build` to extract build configuration (modules, include paths, C macros). Must support multiple Zig versions -- the minimum runtime version can differ from the Zig version ZLS was built with. Uses `@hasDecl`/`@hasField` for version compat. Test it with: `zig build --build-runner src/build_runner/build_runner.zig`.

### Code Generation (`src/tools/`)

`config_gen.zig` generates `src/Config.zig` and `schema.json` from a configuration spec. Run `zig build gen` to regenerate.

### Dependencies

Defined in `build.zig.zon`:
- **lsp_kit** -- LSP protocol types and transport (from zigtools)
- **diffz** -- diff algorithm implementation
- **known_folders** -- platform-specific known folder paths
- **tracy** (lazy) -- optional profiling support

### Key Types

- `zls.Uri` -- URI handling throughout the codebase
- `offsets.Loc` -- byte range (start, end) for source locations
- `offsets.Encoding` -- LSP position encoding (utf-8, utf-16, utf-32)
- `InternPool.Key` -- union of all interned type kinds
