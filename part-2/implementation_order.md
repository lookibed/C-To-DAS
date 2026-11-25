# C-To-DAS Part 2 — Implementation Order

The phases of [very-detailed-plan.md](very-detailed-plan.md) as ordered work items, each
with an acceptance test. This is the document the implementer executes. Read it with Part
1's `c-ir-spec.md` open: the C-IR is the contract, and Dumper A is the reference for every
byte of it.

Items marked **(P)** start with a probe. A probe that contradicts this document is a
finding: report it, then fix the document.

## Working rules {#rules}

1. **Dumper A is the reference.** Where Dumper C and Dumper A disagree, Dumper C is wrong.
   If a finding shows Dumper A wrong, fix Dumper A in the same change, so the two stay
   byte-identical.
2. **`emit.das` does not change before the AST phase.** The only exception is a bug the
   new oracles find.
3. **Fail closed.** Every refusal names the file, line, column and the construct. Dumper
   C accepts no input Dumper A refuses.
4. **Ratchets only grow.** The byte-identical lists, the pass lists and the refusal lists
   never lose a line without a ledger entry.
5. **No clang in the import.** Nothing under `frontend/` or `c_import/` requires `cbind`
   or spawns a process. A `REVIEW.das` gate checks both.
6. **Fast from the first line.** Lex over a byte view. Tokens live in arrays. Identifiers
   are interned integers. Nothing allocates per token.
7. **A daslang gap is a pull request against daslang**, with its own test. No fork, no
   workaround that outlives the pull request.
8. Part 1's rules stay: fixtures before machinery, probe before assuming, no hand edits
   of generated output, findings numbered in the `F` ledger.

## New folders in c2das-re {#folders}

| Folder | Holds |
|---|---|
| `frontend/` | Dumper C: preprocessor, parser, checker, constant evaluator, layout; the C-IR diff tool and its ratchet lists |
| `frontend/include/` | the own libc headers |
| `c_import/` | the `%c_import` reader macro module and its package manifest |

Each folder gets its `ARCHITECTURE.md`, `REVIEW.md` and tests, as the repository's
document system asks.

## Pull requests against daslang {#daslang-prs}

Owned by the implementer. Each lands before the item that needs it.

| Pull request | Needed by |
|---|---|
| A macro registers a non-das file as a `FileInfo`, so an AST node can point into it | AST.3 |
| A macro reads a file through the compile's file access | W.1 |

## Headers {#headers}

**Goal: one header set and one predefined-macro table, seen by both dumpers.**

- **H.1 The header set.** `frontend/include/` with the headers of the plan. Each declares
  what a converted program can call, under the same names: the functions `crt` binds
  under their C names, and the libc names the emitter lowers itself (`printf`, `exit`,
  `qsort`, `sin`, `longjmp`, `signal`: the `C_RUNTIME_CALLS` table of `emit.das`).
  `assert` and `errno` expand to calls of `__assert_fail` and `__errno_location`, the
  names the emitter already maps (rule 2).
  Acceptance: a test reads the functions `crt` exports from the live module, the names
  the emitter lowers, and the prototypes the headers declare. The prototypes equal the
  first two lists together. The `crt` exports with no C prototype (the `c_*` helpers,
  the per-directive `snprintf_*`, `sscanf_*` and `fscanf_*` families) and glibc's alias
  spellings are a short list of exceptions in the test, each with its reason.
  Probed 2026-11-26: the plain equality of the two lists cannot hold, `crt` exports
  helpers C does not name and binds no `printf`.
- **H.2 The predefined macros.** One table per dialect (`linux`, `msvc`): the platform
  names, the sizes, `__STDC_VERSION__`. The table is a file both dumpers read. **(P)**
  Dumper A runs clang with `-undef` plus the table as `-D` entries, so clang's own
  predefined names (`__GNUC__`, `__clang__`, `_MSC_VER`) are gone and both dumpers
  preprocess the same input.
  Probed 2026-11-26 (clang 22.1.8): `-undef` takes the predefined macros from 408 to 8.
  The standard ones stay: `__STDC__` (under the linux triple only), `__STDC_HOSTED__`,
  `__STDC_VERSION__`, `__STDC_UTF_16__`, `__STDC_UTF_32__` and the three `__STDC_EMBED_*`.
  The table states them too, and a `-D` over one works. `__STDC_VERSION__` is `201710L`:
  Dumper A passes no `-std`, so Part 1 ran clang's default, gnu17. The built-in names
  that are no table entries (`__FILE__`, `__LINE__`, `__COUNTER__`, `__has_include`,
  `__has_attribute`) stay as well; Dumper C's preprocessor implements or refuses each
  (PP.3, PP.4).
- **H.3 Dumper A on the own headers.** `-nostdinc` plus `frontend/include/`; the folder
  counts as external, as the system directories do today. Then delete the glibc special
  cases (`__NO_CTYPE`, the statement-expression `assert`).
  Acceptance: every suite keeps its pass list; every project passes its own check
  (demo-sync, the Lua suite, the project outputs). c2das-ports is regenerated and the
  text diff is reviewed once.

## Preprocessor {#preprocessor}

**Goal: the same token stream as clang, measured for speed.**

- **PP.1 Lexer.** pp-tokens over a byte view; each token has a file id, an offset, a line
  and a column.
- **PP.2 Directives and includes.** `#include` through one file-provider interface (the
  first provider reads with `fio`), include dirs in order, `#pragma once`, include
  guards, `#line`, `#error`, `#pragma pack` recorded for the layout.
- **PP.3 Macro expansion.** Object-like, function-like, variadic, `#`, `##`, rescanning
  with hide sets, `__FILE__`, `__LINE__`. The definitions of H.2 and of the import's
  `defines` are set before the first line.
- **PP.4 `#if`.** The expression evaluator, `defined`, `#elif`, nesting.
- **PP.5 The expansion record.** Every token keeps its spelling location, its expansion
  location and the macro call it came from, with the call's argument text. The Core and
  Aggregates phases write the C-IR's macro fields from it.
- **PP.6 Token oracle.** Run `clang -E` under H.2's flags, lex its output with PP.1,
  compare token by token.
  Acceptance: clean on every suite file and every unit of every project.
- **PP.7 Speed probe.** Preprocess PureDOOM under the interpreter natively and under the
  wasm interpreter. Record tokens per second in the ledger. The owner sets the bar from
  that number.

## Core {#core}

**Goal: byte-identical C-IR for scalar programs.**

- **C.1 Parser.** Expressions, declarations and declarators, statements, with the typedef
  table. Scalars, pointers and functions only. Recursive descent, or `modules/dasLR1`
  grown into a bison-like generator (the plan's note under Dumper C): the implementer's
  choice. If dasLR1, its extension is a pull request against daslang and lands first.
- **C.2 Types.** The type table in the spec's interning order, each `spell` as clang
  spells it.
- **C.3 Conversions.** Promotions, usual arithmetic conversions, lvalue conversion,
  decay, null pointer constants, assignment and argument conversions, each a cast node
  with its pinned `castKind`.
- **C.4 Names.** As Dumper A names things: `<stem>__<name>` for file statics, hoisted
  local statics, block-scope `extern`, the parameter and local renames, references bound
  by declaration and never by spelling.
- **C.5 Output.** Dumper C builds `cir.das`'s `CirTu` values; `write_cir` writes them. No
  second writer.
- **C.6 The diff and its ratchet.** `frontend/diff.das` byte-compares the two dumpers'
  C-IR with the macro fields stripped, the one normalization the spec allows. A list per
  suite holds the byte-identical inputs. `--dumper a|c` selects the dumper in
  `converter/main.das` and in the suite runners.
  Acceptance: byte-identical on every suite test whose C-IR has no record, union, enum or
  array type; the list of those tests is computed from Dumper A's output.

## Aggregates {#aggregates}

**Goal: byte-identical C-IR for every suite test.**

- **A.1 Records, unions, enums, arrays.** Anonymous members, flexible array members, the
  enum width and sign rule of the dialect, array dimensions spelled by enum constants
  (`dims`).
- **A.2 Layout, `linux`.** Sizes, alignments, offsets and bit offsets by the dialect's
  rules, `packed`, `#pragma pack(n)` and the `aligned` attribute included. The `packed`
  verdict comes from the existing law in `bit_units.das`.
- **A.3 Initializers.** Designators resolved to positions, array fillers, the union
  member, braced scalars, compound literals, character arrays from string literals.
- **A.4 Constant evaluator.** Integer constant expressions, address constants of static
  initializers, `sizeof`, `_Alignof`, the `offsetof` node, float folding to hex-floats,
  `__builtin_constant_p` with clang's answers and a refusal where the answer is not
  certain.
- **A.5 The rest of Dumper A's subset.** `switch`, `case` and label markers flattened the
  same way, `goto`, the opaque `va_list` and `jmp_buf` records, `va_arg`, the
  `__builtin_*` names, the dropped and read attribute lists, the asm barrier.
- **A.6 Macro fields.** The `macros` table, `macro`, `fn_macro` and `macro_args`, written
  from PP.5. Dumper C knows every expansion exactly, so it marks more sites than Dumper
  A's matching finds. The fold verdict stays the emitter's. The suites and the projects
  are the oracle for these fields, since the byte-diff strips them.
- **A.7 Refusals.** A list per suite of the tests Dumper A refuses.
  Acceptance: byte-identical on every suite test Dumper A accepts; a refusal on every
  test of the refusal lists.

## Projects {#projects}

**Goal: Part 1's results with no clang.**

- **PR.1 The projects.** Byte-identical C-IR, in this order: Lua, PureDOOM, doomgeneric,
  binjgb, h264bsd-mp4, plmpeg-stream, wasm3, quakegeneric.
- **PR.2 The `msvc` dialect.** Widths and record layout. Dumper A gives the reference on
  the same box: with the own headers, `-target x86_64-pc-windows-msvc` needs no Windows
  SDK.
- **PR.3 Suites end to end.** The three runners with `--dumper c`; the csmith
  differential run nightly with it.
  Acceptance: each `expected_pass.txt` passes.
- **PR.4 The no-clang lane.** A daslang build with dasClangBind off, no clang on `PATH`.
  It runs PR.3 against recorded reference outputs, and later the Import and Web checks.
- **PR.5 Error text.** One ledger of the refusals users are likely to meet, each with its
  message as printed.

## Import {#import}

**Goal: `require doom`.**

- **I.1 The macro.** `c_import/c_import.das`: the reader macro, its body (`files | defs`,
  or a `.c2das` path with optional `| defs`), paths read beside the wrapper file.
- **I.2 The pipeline in process.** Dumper C, `link.das`, `emit.das` in the `single`
  layout, the text returned from `suffix`. The formatter runs only for the text flag.
- **I.3 Module setup.** A converted module opens with `options` lines (`solid_context`,
  `stack`, `strict_aliasing = false`). A macro cannot set them, so the import splices
  none: they are module setup, written by hand in the wrapper module or in the program.
  The package's documentation names the three and what each is for: `solid_context` is
  speed; `stack` is room for deep C recursion; `strict_aliasing = false` turns off the
  typed aliasing of the JIT and the exe, which C code that reads one object through two
  types needs. The suite wrappers of I.8 and the Doom and Lua wrappers of I.9 write the
  lines Part 1's modules carry.
- **I.4 Cache pins.** `add_module_cache_dependency` for every C file, header and sidecar
  the import read.
  Acceptance: the plan's cache probe, on a real import: an edited header recompiles, an
  untouched one stays warm.
- **I.5 The surface.** External linkage is public, file statics are private. A prototype
  with no body binds to `crt` by name, else an error naming it. A C `main` is exported as
  `c_main`, so it never meets a das `main`.
- **I.6 Errors.** A frontend error reaches the user through `macro_error`, with the C
  file, line and column in its text.
- **I.7 The text flag.** One switch writes the spliced module to disk, formatted. That
  file is Part 1's converter output.
- **I.8 Suites as imports.** A generator wraps each passing suite test in a wrapper
  module and a das `main` that calls `c_main`.
  Acceptance: the pass lists hold under the interpreter and the JIT.
- **I.9 Doom and Lua.** The Doom host and the Lua harness require a wrapper module.
  Acceptance: demo-sync on demo1, demo2 and demo3 under the interpreter, the JIT and
  AOT; the Lua test suite passes; both in the no-clang lane.
- **I.10 The package.** A daspkg manifest for `c_import`, with `c_runtime`, `crt` and the
  headers.

## Web {#web}

**Goal: the headline metric.**

- **W.1 File access.** A second file provider reads through the compile's file access
  (needs the daslang pull request).
- **W.2 The Doom example.** A playground example: a das host that requires `doom`. The
  page ships PureDOOM's C sources and `freedoom2.wad`; the browser compiles the C.
  Acceptance: it plays demo1 in the playground, and the per-tic checksums equal the
  reference log.
- **W.3 The playground example.** `stb_voxel_render.h` behind a wrapper module, the world
  built in das, the shader written in das with the GLSL emitter. **(P)** a mesh mode
  whose data sits in vertex attributes alone.
  Acceptance: the example runs in the playground; an edit of its C text or of a
  definition recompiles in the browser.
- **W.4 Speed in the browser.** The import's compile time on the example and on PureDOOM,
  recorded in the ledger against PP.7's bar.

## AST {#ast}

**Goal: no text between C and the das module.**

- **AST.1 Split `emit.das`.** A decision layer and a spelling layer.
  Acceptance: every file of c2das-ports regenerates byte-identical; the golden hashes of
  `converter/tests` hold.
- **AST.2 The AST spelling layer.** It builds the module's declarations and bodies from
  the same decisions.
- **AST.2a Aliasing.** The AST layer sets `strict_aliasing` off on the module it builds,
  under the sidecar's `strict_aliasing` key as in Part 1. It is the one option of I.3 the
  import sets itself; `solid_context` and `stack` stay module setup.
- **AST.3 C locations.** Every node points at its C file, line and column (needs the
  daslang pull request).
- **AST.4 Annotations.** **(P)** whether `[c_function]`, `[c_union]`, `[c_bitfields]` and
  `[variadic]` apply to declarations a macro adds. If they do not, the AST layer builds
  the expanded form.
- **AST.5 The oracle.** Each suite test and each project through both layers.
  Acceptance: the same output on every tier.
- **AST.6 The switch.** The AST layer is the import's default. The text layer stays
  behind I.7's flag.
- **AST.7 C coordinates.** Three tests: a C type error, a runtime panic and a debugger
  step each name the C file and line.
