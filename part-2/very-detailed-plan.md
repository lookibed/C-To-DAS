# C-To-DAS Part 2 — C import

Part 1 converts C to daslang source, with clang as the frontend. Part 2 removes clang and
removes the generated source: a daslang module names C files, and daslang compiles them.

```das
// doom.das
module doom public
require c2das/c_import

%c_import~ doom.c2das %%
```

```das
// game.das
require doom

[export]
def main {
    doom_init(...)      // a C function, called directly
    var p : player_t    // a C struct, visible as a das struct
}
```

Headline metric: **`require doom` runs PureDOOM on a box with no clang installed,
demo-sync verified, on every tier; the same program runs on a web page; and the playground
has a das example that requires C and compiles it live in the browser.**

Part 1's documents stay normative for everything they cover: the C-IR
(`c-ir-spec.md`), the lowerings (`lowering-examples.md`), the C library
(`stdlib-examples.md`), the feature matrix. This plan adds only what is new.

[implementation_order.md](implementation_order.md) expands the phases into ordered work
items with acceptance tests. [acceptance.md](acceptance.md) is the explicit list Part 2 is
accepted against.

Facts marked **(P)** are not probed yet. Each one is a probe in the first phase that needs
it. The plan is finished when no **(P)** remains. The probes already run are under
`probes/`, on daScript `79c48e0173`.

## Decisions locked (discussion 2026-11-20) {#decisions}

| Decision | Choice | Why |
|---|---|---|
| Seam | **C-IR.** The new frontend is **Dumper C**, a third producer of C-IR. The backend does not change while the frontend is built | The seam cuts the job in two. Each half has its own oracle |
| Frontend | Written in daslang: preprocessor, parser, type checker, constant evaluator, record layout. No clang at run time, no native module | It runs wherever daslang runs, the browser included |
| Backend | Two steps. First a **text splice**: the reader macro returns `emit.das`'s text. Then a **direct AST** backend replaces it | The text step is the proof of concept and reuses the tested emitter as is. The AST step gives C file and line on every node |
| Module shape | A wrapper module: `module blah public`, the import macro inside. With the AST backend the module is built on the fly | Two users of one C library `require` one module and see the same types |
| System headers | **Our own**, a small libc header set that declares what `crt` binds | Parsing glibc or UCRT headers is most of the pain of a C frontend, and none of the value |
| ABI | **Unchanged from Part 1.** Dumper C writes the C layout facts the C-IR carries. The emitter maps them to das structs as it does today | What Part 1 generates is already the das ABI |
| Pack | **Out.** No new language support. If packed records become an issue, support lands at the language level | Part 1 already handles them without it ([how](#layout-today)) |
| Cache | The frontend pins every file it reads with `add_module_cache_dependency` | A warm module cache does not run the macro, so the cache must know the C files |
| Dialect | C99 as in Part 1. No C++ | Same input set, same oracle |
| Acceptance | The same suites and the same projects as Part 1 | The expected-pass lists already exist |
| Definitions | Passed in the macro body after a `\|` ([Definitions](#definitions)) | Same spelling as the sidecar's `defines` |
| C macros from das | Not exported; the user writes a C accessor ([how](#macros-from-das)) | The macro expands inside C, where its types are known |
| Playground example | `stb_voxel_render.h`, the shader written in das | A 3D result, and its configuration shows the definitions |
| das-facing strings | As converted: a `const char *` parameter is `uint8?`, the caller writes `cstr("text")`. The wrapper module adds the friendly signatures a library needs | A generated `string` overload has to guess which `char *` is text and which is a buffer C writes into |
| Shared headers | One import is one closed C program. Libraries that share types go into one import | The sidecar already takes a file list; reuse of another import's types waits for a project that needs it |
| Dumper B | **Retired.** The Rust producer is no oracle of Part 2 and owes no C-IR addition | Dumper A is the reference; a C-IR change is then owed twice, not three times |
| Home | c2das-re, shipped as a daspkg package while it is built. Moving it into the daslang repo is decided after the **Import** phase passes | The playground loads a package; the in-tree move waits for a working import |

## Success metrics {#metrics}

1. **Same frontend answers.** Dumper C's C-IR is byte-identical to Dumper A's on every
   suite test (2058 ids) and every project (Lua, PureDOOM, doomgeneric, binjgb,
   h264bsd-mp4, plmpeg-stream, wasm3, quakegeneric).
2. **Same pass lists.** Each suite's `expected_pass.txt` passes with Dumper C in place of
   Dumper A. Today: c-testsuite 203, csmith 182, gcc-torture 1204.
3. **No clang.** One CI lane runs on a daslang build without dasClangBind, with no clang
   on `PATH`. Everything in metrics 2, 4 and 5 passes there.
4. **Import.** `require doom`: demo-sync on demo1, demo2 and demo3 under the interpreter,
   the JIT and AOT. `require lua`: the Lua test suite passes.
5. **Web.** Two playground examples, each a das program that requires C, compiled in the
   browser from C sources: PureDOOM behind `require doom`, and `stb_voxel_render.h`. An
   edit of the C text recompiles in the browser.
6. **C coordinates** (AST backend). A C type error, a runtime panic and a debugger step
   each name the C file and line.

## What Part 1 gives us {#part-1}

- The C-IR contract and its canonical bytes. It already demands what a frontend must get
  right: every implicit conversion as a cast node, constants folded, initializers
  positional, layout baked in.
- `emit.das`, the emitter the pass rate lives in, with `link.das` and the `c_runtime`
  macros. It reads C-IR only.
- Dumper A (clang). It stays as the oracle. It is never loaded by an import.
- The suites, their runners and ratchets, the seven projects, the Doom demo-sync harness.
- c2das-ports: generated output of every project, byte-stable. A golden file set.

### How Part 1 handles layout today {#layout-today}

The emitter needs no pack support from the language:

- A natural C struct is a das struct. das lays it out as C does.
- A bitfield record is a das struct under `[c_bitfields]`. The macro adds backing fields
  and one property accessor pair per bitfield, so `s.a` reads and writes the bits.
- A union is a das struct under `[c_union]`: one storage field, and one accessor per
  member that returns a reference into it.
- A packed record whose plain fields still land on their das alignment is a plain struct
  with `uint8[n]` byte units and `_pad<N>` padding fields.
- Any other packed record is marshal-only: the sidecar names it, it lives as C bytes, and
  generated readers and writers move its fields.

Part 2 keeps all of this. Dumper C only has to report the same offsets clang reports.

## Architecture {#architecture}

```
 blah.das:  %c_import~ ... %%
                │
                ▼
 FileAccess ─► preprocessor ─► parser ─► checker ─► C-IR (in memory) ─► link.das
                    ▲                                    │                  │
              own libc headers                  write_cir (oracle runs)     ▼
                                                              emit.das ─► text ─► splice     step 1
                                                              AST backend ─► das module      step 2
```

### Dumper C {#dumper-c}

Four parts. Each one owns a list of C-IR obligations.

**Preprocessor.** Line splicing, pp-tokens, `#include` through the include path,
object-like and function-like macros, variadic macros, `#` and `##`, rescanning by
clang's and gcc's model (a macro is disabled while its replacement is rescanned; not
Prosser's per-token hide sets), `#if` expressions with `defined`, `#pragma once`, `#line`, `#error`, the predefined
macros of the dialect. Every token keeps its spelling location, its expansion location
and the macro it came from. That record gives the C-IR's macro fields directly; Dumper A
has to rebuild them from clang's dump by matching offsets.

**Parser.** The C99 grammar by recursive descent, with a scope-aware table for the
typedef-name ambiguity. It accepts exactly the GNU spellings Dumper A accepts
(`__extension__`, the two attribute lists, `__func__`, the named `__builtin_*` calls) and
fails closed on the rest with file, line and column.

A note, not a requirement: daslang has `modules/dasLR1`, an LALR(1) table builder written
in daslang. Today it is an acceptor over bytes: it answers yes or no, it has no actions,
and it forks its stack at a conflict. Grown into a bison-like generator it would parse C
from a grammar close to the C standard's own. That needs:

- token kinds as terminals, where it has byte classes now;
- a value stack and one action per production;
- a single-stack driver that works in place, with precedence and associativity
  declarations to settle conflicts, and a build that reports the ones left;
- the tables built once (at compile time, or written out as das source) and not on every
  use.

Actions run during the parse, so the typedef table can feed the lexer as the classic
yacc C grammars do. The implementer chooses between this and recursive descent. The
oracles do not see the difference.

**Checker.** Scopes and linkage (tentative definitions, block-scope `extern`, the
`<stem>__<name>` rename of file statics, hoisted local statics). Types and their
composition. Integer promotions, usual arithmetic conversions, decay, null pointer
constants and assignment conversions, each written as a cast node with the pinned
`castKind`. The constant evaluator: enum values, case labels, array sizes, `sizeof`,
`_Alignof`, `offsetof`, static initializers. Initializers in positional form. String
literals as bytes. Float literals as hex-floats.

**Layout.** The record layout rules of the dialect: sizes, alignments, field offsets, bit
offsets, `packed` and `#pragma pack(n)`. Two dialects, as in Part 1: `linux` (LP64; also
macOS and wasm64) and `msvc` (LLP64). `long` follows the host, because `crt` binds the
host's C library.

Rules for all four parts:

- **Fail closed.** A construct Dumper C cannot represent exactly is an error with a
  location, never a guess. It accepts no input Dumper A refuses.
- **Read through `FileAccess`.** Every source and header is read through the compiler's
  file access, never through `fio`. The playground's in-memory files then work, and one
  call pins the file for the module cache. **(P)** the das API a macro reads a file
  through; `set_file_source` and `add_file_access_root` exist, a read call is to be found
  or added.
- **Fast from the first line.** The frontend runs at compile time, under the interpreter,
  and in the browser under the wasm interpreter. Lex over a byte view, keep tokens in
  arrays, intern identifiers as integers, allocate nothing per token. The speed is
  measured at the end of the preprocessor phase, natively and in wasm, on PureDOOM; the
  bar is set from that number.

### Own libc headers {#own-headers}

One folder of headers: `stdio.h`, `stdlib.h`, `string.h`, `math.h`, `ctype.h`,
`stdint.h`, `stddef.h`, `stdarg.h`, `stdbool.h`, `limits.h`, `float.h`, `errno.h`,
`time.h`, `setjmp.h`, `assert.h`, `signal.h`, `locale.h`, `inttypes.h`. They declare what
a converted program can call, under the same names, and nothing else: what the `crt`
module binds under its C names, and the libc names the emitter lowers itself (`printf`,
`exit`, `qsort`). The list grows on suite demand, as `c_runtime` did.

- A `<...>` include resolves to this folder only. An include it does not hold is an error
  that names the header.
- `FILE` is opaque. `struct tm` and `struct lconv` are written out. `jmp_buf` and
  `va_list` are the two opaque records Part 1 already defines.
- `assert` and `errno` are plain calls, of `__assert_fail` and `__errno_location`, the
  names the emitter maps. The glibc-shaped special cases of Dumper A
  (`__NO_CTYPE`, the statement-expression `assert`) are not needed.
- **Dumper A runs on the same headers** (`-nostdinc` plus this folder). Both dumpers then
  see one input, and clang checks our headers for free.

### The import macro, step 1: text splice {#text-splice}

`%c_import~ ... %%` is a reader macro. Its `suffix` method returns das source text, and
the compiler parses that text in place. `daslib/spoof.das` works this way today.

- The macro body names a sidecar (`doom.c2das`) or lists C files, then the definitions
  ([Definitions](#definitions)). The sidecar format is Part 1's: files, `include_dirs`,
  `defines`, the union and marshal policies.
- The macro runs Dumper C on each file, links with `link.das`, emits one module's text
  with `emit.das` in the `single` layout, and returns it.
- It calls `add_module_cache_dependency` for every file it read.
- A flag writes the text to disk. That is Part 1's converter, on the same code path.
- The das-facing surface is the converted program as it is: functions with external
  linkage are public under their C names, file statics are private, structs, enums,
  typedefs and constant macros are visible. A function-like macro is a `[c_macro]`
  function where Part 1's fold accepts it.
- A prototype with no body in the listed files binds to `crt` by name, or is a libc name
  the emitter lowers itself (`printf`, `exit`, `qsort`), as the own headers declare. Any
  other name is an error that names the symbol.
- Probed 2026-11-20 (`probes/`): a macro that stands right after the wrapper's own
  `require` lines splices `require` lines, a struct and a function; the wrapper's later
  functions call the spliced one, and a module that requires the wrapper sees all of it.
- Probed 2026-11-20 (`probes/`): with a file pinned by `add_module_cache_dependency`, a
  warm run does not run the macro, an edit of the file runs it again, and the next run
  is warm.
- The import splices no `options` line; a macro cannot set them. `solid_context`, `stack`
  and `strict_aliasing = false` are module setup, written in the wrapper or the program.
  With the AST backend the import sets `strict_aliasing` itself, and only that one.
- One import is one closed C program. Two imports that share a header get two copies of
  its types; sharing a header between imports is a later item.

### Definitions passed to the C program {#definitions}

The das side passes `#define`s to the C program in the macro body, after a `|`:

```das
%c_import~ stb_image.h | STB_IMAGE_IMPLEMENTATION=1 %%
%c_import~ doom.c2das | FEATURE_SOUND | MAXPLAYERS=4 %%
```

- Each entry is spelled as the sidecar's `defines` entries are: `NAME`, `NAME=value`,
  `NAME(params)=value`. `NAME` alone is `NAME=1`, as `-DNAME` is. One parser serves both.
- Dumper C's preprocessor defines them before the first line of every unit of the import.
- Order: the dialect's predefined macros (the platform, the sizes), then the sidecar's
  `defines`, then the body's. A later entry of the same name wins.
- A value is literal text. The macro runs at parse time, so a das constant is not known
  there.
- One wrapper module is one set of definitions. A second set is a second wrapper module,
  and its types are its own.

### C macros seen from das {#macros-from-das}

The import exports no macro. A C macro reaches das through C code the user writes in a
file of the import:

```c
int max_players(void) { return MAXPLAYERS; }                 // a constant
void pop(lua_State *L, int n) { lua_pop(L, n); }             // a function-like macro
```

Each is an ordinary C function, so das calls it as any other. The frontend needs nothing
new: the macro expands inside C, where its types are known. Part 1's `let private` and
`[c_macro] def private` stay private to the converted module.

### The import macro, step 2: direct AST {#direct-ast}

The AST backend builds the das module from the C-IR without text.

- **Split `emit.das` first.** Today it decides and spells in one pass. The split gives a
  decision layer (names, loop shapes, switch tiers, layout mapping, summaries) and a
  spelling layer. The gate for the split: every file of c2das-ports regenerates
  byte-identical.
- **Add a second spelling layer** that builds AST nodes. Both layers take the same
  decisions.
- **Every node carries its C location.** The C files are registered as file infos of the
  program, so errors, stack traces, the debugger and the profiler show C lines. **(P)**
  registering a non-das file as a `FileInfo` from a macro.
- **(P)** the `c_runtime` annotations (`[c_function]`, `[c_union]`, `[c_bitfields]`,
  `[variadic]`) on declarations a macro adds. If the compiler does not apply an
  annotation to an added declaration, the AST layer builds the expanded form itself.
- Comment carry, line wrap and the multi-module layouts stay text-only.

## Verification {#verification}

Each oracle checks one part alone.

| Oracle | Checks | How |
|---|---|---|
| Headers | own libc headers | Dumper A with `-nostdinc` and our headers: the suites and projects keep their pass lists |
| Tokens | preprocessor | token stream against `clang -E` on every suite file and every project unit |
| C-IR | parser, checker, layout | byte-diff against Dumper A. A ratchet file lists the byte-identical inputs; it only grows |
| Suites | Dumper C end to end | the existing runners with Dumper C; pass lists as in Part 1 |
| Import | the macro, the cache pins | every passing suite test wrapped as an import and run; an edit of the C file under a warm cache recompiles |
| AST | AST backend | text backend against AST backend on one input: same output on every tier, over the suites and the projects |
| Doom | everything | demo-sync through `require doom`, per tier |
| No clang | the claim itself | the CI lane of [metric 3](#metrics) |

The refusals are checked too: an input Dumper A refuses, Dumper C refuses.

## Phases {#phases}

No sizing. Order and exit criteria only.

| Phase | Work | Exit criterion |
|---|---|---|
| **Headers** | The own libc header set; Dumper A switched to it | Suites and projects pass on our headers under Dumper A |
| **Preprocessor** | Dumper C's preprocessor on `FileAccess`; the token oracle; the speed probe | Token-diff clean on every suite file and project unit; speed measured natively and in wasm, bar set |
| **Core** | Parser and checker for scalars, expressions, statements, functions; C-IR writer; the byte-diff ratchet | Byte-identical C-IR on the scalar-only suite tests |
| **Aggregates** | Records, unions, bitfields, enums, arrays, initializers, the constant evaluator, layout for `linux` | Byte-identical C-IR on every suite test Dumper A accepts; the same refusals |
| **Projects** | Lua, PureDOOM and the other projects; the `msvc` dialect; the no-clang lane | Byte-identical C-IR on all projects; pass lists hold with Dumper C; no-clang lane green |
| **Import** | `%c_import`, the wrapper module, cache pins, the text flag | Suites pass as imports; `require doom` demo-sync on every tier; `require lua` passes the Lua suite |
| **Web** | Both playground examples: Doom through `require doom`, and Voxel | [Metric 5](#metrics) |
| **AST** | The `emit.das` split; the AST spelling layer; C locations | AST oracle clean; [metric 6](#metrics); the text splice is off by default |

The headline metric is true at the end of **Web**. **AST** changes how it is built, not
what it does.

## Risks {#risks}

| Risk | Severity | Answer |
|---|---|---|
| Cast-stream parity: clang's exact sequence of implicit conversions, `NoOp` and `LValueToRValue` included | high effort | The byte-diff makes it mechanical: each mismatch is one small repro |
| Clang spellings in the C-IR (type `spell` strings, anonymous record names, interning order) | med | The spec pins them; Dumper C copies them |
| Constant evaluator parity, `__builtin_constant_p` above all | med | Fail closed where the answer is not certain |
| Frontend too slow under the interpreter or in wasm | med | Measured at the preprocessor phase; data layout rules from the first line; the module cache makes it a one-time cost |
| Two emitters drift apart | med | One decision layer; the AST oracle over every suite |
| Annotations on macro-built declarations do not apply | low | The AST layer builds the expanded form |
| Error messages are now ours (clang wrote them before) | low | File, line, column and the construct's name on every refusal; a ledger of the ones users hit |
| A project needs a header we do not have | low | Demand-driven header list, as `c_runtime` |
| Record layout rules of two ABIs | low | Small, documented algorithms; `probes/test_layout.das` already holds the hard cases |

## Sidequests (daslang core) {#sidequests}

Part 2 never blocks on these. Each has a fallback.

| Sidequest | Motivation | Fallback |
|---|---|---|
| Pack and alignment at the language level | Packed records as plain structs | Part 1's byte units, padding fields and marshal-only records |
| A file read through `FileAccess` for macros | In-memory files in the playground; one read path | Read by path and pin by hand. The implementer makes the pull request against daslang |
| A foreign `FileInfo` for AST nodes | C lines in errors and the debugger | das lines of the wrapper module. The implementer makes the pull request against daslang |
| Annotations applied to macro-built declarations | The AST layer stays small | Build the expanded form |
| Multi-file examples in the playground | A `.c` file beside the das example | The C text inside the macro body |

## Open questions (for Boris, one at a time) {#open-questions}

None. Every question of the 2026-11-20 discussion is a row of [Decisions](#decisions).

The mesh mode of the playground example is a probe of the **Web** phase: **(P)** a
`stb_voxel_render.h` mode whose data sits in vertex attributes alone, since WebGL2 has no
texture buffer.
