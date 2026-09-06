# C-To-DAS — Implementation Plan

A C-to-daslang source converter. Frontend: libclang via dasClangBind (no C parsing built).
Backend: emit gen2 daslang source. Headline metric: **import PureDOOM, convert, run doom2.wad —
demo-sync-verified, benchmarked across interp / JIT / AOT vs native C.**

Companion documents:
- [c-feature-matrix.md](c-feature-matrix.md) — the exhaustive C-feature → das-lowering
  table ("all shapes": bitfields, do/while, switch, goto, unions, varargs, …).
- [lowering-examples.md](lowering-examples.md) — **normative** C → das code pairs, the
  emitter's golden reference. Families enter it only after their discussion round with
  Boris; the plan is finished when every matrix row has its example and no `(P: …)` probe
  tags remain — zero open questions, zero deferred probes.
- [stdlib-examples.md](stdlib-examples.md) — the C standard library's c_runtime designs,
  same contract (discussed sections only, probe tags to zero).
- [sidequest.md](sidequest.md) — daslang core-language follow-ups c2das wants but never
  blocks on (§13 points here).
- [implementation_order.md](implementation_order.md) — §9's phases expanded into ordered,
  acceptance-tested work items; the document the implementer executes.
- [c-ir-spec.md](c-ir-spec.md) — the C-IR interchange format (v0.1): the dumper↔backend
  contract of §4.0, canonical-bytes serialization, pinned castKind enum.

## 1. Decisions locked (discussion 2026-08-21)

| Decision | Choice | Why |
|---|---|---|
| Memory model | **Native + escape hatches** — C structs → das structs, C pointers → das pointers with unsafe arith | Idiomatic output, best interp perf, showcases daslang. Punning sites get generated per-pattern machinery (§5) |
| Tool nature | **Repeatable pipeline** — C stays source of truth, output regenerated at will, hand edits forbidden | Matches the metric verbatim. Escape hatches live in a sidecar config, never in edited output |
| Output quality | **Readable-first** (revised 2026-08-21): wherever semantics allow, prefer the readable mapping (das enums over int constants, range loops, real names) | The output is the *input* to the follow-up story: convert → run → agent-assisted upgrade into a GOOD port. That story is why we generate `.das` at all — the alternative ("just import C" directly via macros, no source generated) is a separate project, explicitly out of scope here |
| Home | **External module repo `c2das`** (name locked 2026-08-21) | Keeps GPL Doom sources out of the daslang repo; standard external-module worktree pattern |
| Frontend | dasClangBind / libclang 22.1.5 | Works on MSVC since `17d1b035a` (probe-verified per memory 2026-06-05); converter itself is written in daslang |
| Doom revision | **PureDOOM (Daivuk)** | id source refactored for embedding: callback table, 320×200 framebuffer (`doom_get_framebuffer(4)` = RGBA), PCM audio (11025 Hz s16 stereo, 512-sample buffers via `doom_get_sound_buffer`), MIDI via `doom_tick_midi` @140 Hz, input via `doom_key_down/up`, `doom_mouse_move`. Single-header option. GPL-2 |
| C dialect | C99 minus VLAs (`setjmp/longjmp` supported — try/recover lowering, probed 2026-08-21) | Covers Doom (C89-era), Lua 5.4 incl. `pcall` (ANSI), and the practical bulk of the suites |
| Target ABI | `int`=32, `long`=32, `long long`=64, pointers = native das pointers | Matches MSVC x64 (LLP64) — same ABI as the native baseline we diff against |
| UB policy | Signed overflow wraps (das is built `-fwrapv`), shifts as hardware, eval order fixed left-to-right | Documented dialect, matches what csmith-safe programs assume |

## 2. Success metrics (the only numbers that matter)

1. **Doom runs**: `c2das doom/` → `daslang doom_main.das` boots doom2.wad, playable with
   keyboard, SFX audible, in a dasImgui window.
2. **Demo sync**: per-tic gamestate checksum identical to the native C build across demo1/2/3
   of doom2.wad. One desync = one semantics bug, bisectable by tic. This is the semantics
   oracle for the whole project.
3. **Suites**: c-testsuite pass-count ratchet to ≥95% applicable; GCC c-torture `execute`
   subset ratcheted with a skip ledger; csmith differential — N seeds, zero divergence.
4. **Perf table** (the deliverable Boris asked for): `-timedemo demo3` realtics → fps for
   native MSVC `/O2`, das interpreter, das JIT, das AOT. Secondary: Lua 5.4 benchmarks.
   **Interp bar: 35 fps** (Doom's native tic rate) at 320×200 on this box — the converter
   optimization tier (§6) exists to hit it; 30 fps is the accepted floor ("I'm game, lol",
   2026-08-21).

## 3. Verified capability ledger (probe-verified 2026-08-21, in-tree binary)

Everything below ran green in one probe script; the P0 phase re-runs it as a checked-in test.

| Capability | Result | Consequence |
|---|---|---|
| `goto label N` / `label N:` | Works at runtime; labels are ints, resolved lexically up enclosing scopes; **computed `goto expr`** exists (`ExprGoto` with int expr) | C `goto` maps ~1:1 — no Relooper needed for the common case. Computed goto covers the switch-as-jump-table lowering |
| Pointer arithmetic `p + 3`, `q - p` | Scaled, **element units** — identical to C | Direct emission under `unsafe` |
| `reinterpret<uint8?>(p)` between pointer types | Works (call syntax `reinterpret<T?>(x)`) | Cast machinery direct |
| `intptr(p)` → int → `reinterpret<int?>` round trip | Works | `(intptr_t)` casts direct |
| `malloc(64ul)` / `free` / `memcpy(dst, src, n)` | Builtins, work | c_runtime allocator is a thin wrapper; Doom's zone allocator needs exactly one big malloc |
| Ternary `c ? a : b` | gen2 native | Direct |
| `-7 / 2 == -3`, `-7 % 2 == -1` | Truncation toward zero | **Matches C99 exactly** — no div/mod shims |
| `-8 >> 1 == -4` | Arithmetic shift on signed | Matches C-on-x86; emit `uint` cast for unsigned `>>` |
| `int8` arithmetic | **Not defined** — must compute in `int`, truncate on store (`int8(int(b)+1)` wraps 127→-128) | This IS C's integer-promotion rule; the promotion pass emits it naturally |
| `double`, `@@fn` + `invoke` | Work | C `double` and function pointers direct |
| **Data structures** (probed 2026-08-21, round 2) | | |
| Struct copy `b = a` | Deep POD copy incl. `int[4]` members + nested structs; bare `f2 = f1` fixed-array copy too | No clone helpers for POD — plain `=` emission |
| `var s : S` param | **Reference** semantics (caller sees writes) | C by-value = emit callee-side local copy; struct return-by-value works |
| Layout | `{int;int16}`=8, offsets natural; `{int8;int64;double}` → 8/16, size 24; `bool`=1 | **Matches clang/MSVC x64 exactly** for unpacked structs — `sizeof`/`offsetof` foldable either side; packed structs stay marshal-only |
| `int[2][3]` | size 24, row stride 12, col stride 4 | Same memory order + index order as C `int m[2][3]` |
| Struct/array literals | `MobjLike(id = 3, speed = 8)` named-init; partial init zeroes rest (= C rule); global `T[N] = fixed_array(...)` of struct literals works | `info.c` giant tables emit as das global literals. **Trap:** `[1,2,3]` is a dynamic `array<int>` literal — fixed arrays require `fixed_array(...)` |
| Self-ref structs, fn-ptr fields | `next : Node?`, `cb : function<(x:int):int>` + `invoke` | Direct |
| **Layout law** (probed 2026-08-21, round 3) | das struct layout == clang C layout for every natural shape tested: decl order, tight small-field pack (0/1/2/4), int64/double 8-align incl. propagation through nested structs, tail padding in `sizeof` AND array-element stride, `function<>` = **8 bytes** (= C fn ptr, so fn-ptr fields keep C offsets) | Divergence only possible via `#pragma pack`/`packed`/`_Alignas` — das has no packing knob; those types are marshal-only (sidecar). Policy regardless: translate `sizeof`/`offsetof` to das-side `typeinfo sizeof` / `typeinfo offsetof<f>(type<T>)` / `typeinfo alignof` (all exist ✓) so intra-program correctness is self-consistent and never depends on the match; the match only has to hold at marshal boundaries |
| Struct-prefix punning + container_of | `reinterpret<Thinker?>(mobj)` and back ✓; `reinterpret<Mobj?>(intptr(th) - typeinfo offsetof<thinker>(type<Mobj>))` ✓ | Doom's thinker pattern maps natively — no escape hatch needed. Converter emits das `struct` only, never `class` |
| Bitfields via property operators (probed 2026-08-21, round 4) | `def operator . f(s)` / `def operator . f :=(var s; v)` give C-identical call sites incl. `s.a += 1` (compound routes through get+set); signed shl/sar sign-extend ✓; C truncation-on-write ✓; backing-unit layout C-exact ✓ | `[inline]` REJECTED on property operators — interp pays a call per bitfield access; JIT/AOT inline. `__`-prefixed names reserved (`_bits0`) |

All round-1 open probes have since been resolved ✓ (goto-over-declaration = C-exact;
struct/fixed-array copy = plain `=`; multi-dim = C order; `intptr` = 8 bytes; computed
goto verified at runtime; `var private`/`def private` ✓). goto under JIT/AOT:
**source-verified** — both emitters implement `ExprGoto`/`ExprLabel` (`aot_cpp.das:1889`,
`llvm_jit.das:4730`); runtime confirmation folds into P0's three-tier hello-world gate.

## 4. Architecture

```
 .c files ──clang──► TU AST ──walk──► C-IR ──passes──► das AST text ──► formatter ──► .das
                    (libclang            (typed, per-function CFG)                    │
                     via cbind)                                                       ▼
                                        sidecar (.c2das config) ──────────────► compile-check (MCP)
```

### 4.0 The C-IR contract — pluggable frontends (Boris 2026-08-21)

The C-IR (§4.2) is not an internal detail: it is a **versioned, serialized interchange
format with a written spec** (`c-ir-spec.md`, an early deliverable), produced "by whoever
dumps". The backend consumes C-IR only. Contract obligations: resolved types **with
layout baked in** (offsets/sizes/bit-offsets — each dumper obtains them its own way),
full conversion stream (castKinds normalized to a pinned clang-22 enum), constants
evaluated, designated initializers pre-resolved positional, string literals as bytes.

Known dumpers:
- **Dumper A (das)**: `clang -Xclang -ast-dump=json` for bodies (verified 2026-08-21 on
  22.1.5: all castKinds present, bitfield widths, semantic-form initializers; ~5.8KB
  JSON/source line) + dasClangBind for layout (`clang_Type_getOffsetOf` /
  `clang_getFieldDeclBitWidth`, header-verified) — a thin normalizing adapter.
- **Dumper B (Rust)**: the c2das (lookibed) C2Rust fork — its post-CBOR typed C AST is
  the most battle-tested C capture available (implicit casts + castKinds native, rav1d-
  class provenance); a C-IR serializer over it is a small module, preserving that
  investment as the mature adapter. Linux/WSL-hosted; fine — dumping is a pipeline step.

Two dumpers, one contract = **differential frontend testing for free**: run both over the
suites, byte-diff the C-IR; every disagreement is a frontend bug with a repro attached.
The suites verify the backend; the dumpers verify each other.

### 4.1 Frontend detail (Dumper A substrate)

- Parse each TU with fixed flags (or compile_commands.json). dasClangBind gives cursor
  traversal; c2das adds **statement/expression-level** walking — dasClangBind today binds
  declarations only, bodies are new ground.
- **Known libclang gap — implicit casts**: libclang exposes implicit conversions poorly
  (historically `UnexposedExpr`). Mitigation: we don't need them from clang — the converter
  implements C's integer promotions + usual arithmetic conversions itself (it must anyway,
  see §3 int8 finding) and recomputes every implicit conversion from operand types.
  Fallback if operator/detail coverage in libclang 22 still leaks: hybrid frontend reading
  `clang -ast-dump=json` (which does expose `ImplicitCastExpr`) — JSON parsing is
  `sprint_json`/`sscan_json` territory, already stdlib.
- Layout facts (struct offsets, sizes, alignment, bitfield widths) come from
  `clang_Type_getOffsetOf` / `clang_Type_getSizeOf` — used by the marshal generator (§5.1)
  and `sizeof`/`offsetof` folding.

### 4.2 C-IR

Small typed IR in das (structs + variants): decls, types, per-function statement trees with
an explicit CFG only where goto/switch demands it. Decouples clang's shape from emission and
gives the passes a stable substrate. Passes, in order:

1. **Type resolve + rename** — map C types per matrix; rename identifiers colliding with das
   keywords (`table`, `array`, `label`, `in`, `deref`, …) via `_c_` prefix; disambiguate
   file-scope statics with a per-TU prefix.
2. **Promotion insertion** — implement C6.3 conversions; emit explicit casts; all `char`/`short`
   arithmetic computes in `int`/`uint` and truncates on store (das forces this — happily it
   is exactly the C rule).
3. **Statement-ification** — C expressions with side effects (assignment-as-expression,
   pre/post `++`, comma operator, calls inside conditions) become temp-var statement
   sequences in fixed left-to-right order. Short-circuit and ternary with side-effecting
   operands lower to `if` chains.
4. **Control-flow lowering** — do/while, for-with-comma, switch (§ matrix), goto edge cases
   (goto-into-nested-block flattening, Duff fallback via computed goto).
5. **Escape-hatch application** — sidecar-driven punning machinery (§5).
6. **Emission** — gen2 das source through a text builder; `format_file`; `compile_check` gate.

### 4.3 Module mapping — the cyclicity problem

C TUs reference each other freely, including cycles; das modules must be acyclic.
**Resolution: whole-program emission** — one das module per C program (Doom → one module, or
one per strongly-connected component with a shared `globals` module first). Risks: das
compile time on a very large generated module (Doom ≈ 40 kLOC C; `info.c` alone is a
multi-thousand-line static table). Mitigations: split by SCC, move giant const tables into
their own modules, measure compile time as part of P6 and only then optimize.

### 4.4 Sidecar config

Per-project `.c2das` file (das-literal or JSON): union policies (§5.3), cast-site marshal
markers, function-pointer shim groups, symbol renames, file→module mapping, entry points,
libc mapping overrides. The pipeline is repeatable **because** all per-project judgment
lives here, never in the output.

### 4.5 Generated-code policy

Output is generated, not house code: header banner, `options` block relaxing lint
(no PERF/STYLE gates on it), formatter still runs so diffs are stable. Never checked into
the daslang repo; golden output hashes only.

## 5. Escape hatches (the native-model support beams)

### 5.1 Raw-bytes → struct casts (the WAD path)

Doom reads WAD lumps and casts byte pointers to packed structs (`mapthing_t`,
`patch_t`, …), then reads them **in place, per frame** (renderer walks `patch_t` columns).
Plan: generated per-type **marshal readers** (`read_mapthing_t(bytes, ofs)`) built from
clang layout info, applied at the lump-cache boundary (`W_CacheLumpNum` already centralizes
this — the same hook big-endian ports used for byte-swapping, so the sites are enumerable
and finite). Sidecar marks which cast-target types get marshal-on-load vs (later, if perf
demands) an aliasing byte-view accessor.

### 5.2 Function-pointer unions (`actionf_t`)

Doom's action pointers pun between arities (`void(*)(mobj_t*)` vs `void(*)(player_t*,
pspdef_t*)` vs think functions). Plan: a generated **dispatch shim** — a das variant over
the concrete signature families plus wrapper functions; call sites through the union go
through the shim. Sidecar lists the union groups (Doom has essentially one).

### 5.3 Data unions — `[c_union]` annotation macro (revised 2026-08-21)

Readability answer (Boris: "declaration itself needs to be human readable"): not comments —
a **declaration-preserving structure-annotation macro** in c_runtime. Converter emits the
union as a das struct listing the members with their C types under `[c_union]`; the macro
rewrites fields into one max-size/max-align `_storage` and synthesizes property operators.
Punning is memcpy semantics by construction (C11-defined). Probed ✓ (2026-08-21): **one
ref-returning operator per member** (`def operator . pt(var s : U) : Point&` via
reinterpret of storage) covers read, write, compound assign, nested `u.member.field = x`,
and addr-of — no get/set pairs needed. Feasibility of the macro itself: `[decs_template]`
proves struct rewriting; remaining P0 probe — storage alignment (max-align member type, or
`[align_as]` from §13). Perf: interp pays a property call per access — Lua's `TValue`
union is the hot case (JIT/AOT inline). Approved by Boris 2026-08-21.

### 5.4 Bitfields — `[c_bitfields(f = width, ...)]` annotation macro

Same mechanism, same rationale: C-shaped declaration, macro generates the probed
backing-unit + property-operator layer (signed shl/sar sign-extend, C truncation, compound
assign via get+set — all probe-verified 2026-08-21). Doom uses none; suites/csmith do.

### 5.5 `[c_function]` — the whole-body unsafe wrapper (probed 2026-08-21)

The bulk of C machinery is unsafe in das terms (pointer arith, deref, reinterpret,
malloc/free) — per-op `unsafe` wraps would drown the output in noise. `[c_function]` is a
~15-line c_runtime function-annotation macro that replaces the body with
`qmacro_block() { unsafe { $e(func.body) } }` (precedent: `daslib/apply_in_context.das:77`;
`$e` splices-and-clones, no pre-clone — PERF023). Probed end-to-end: a body full of raw
pointer arithmetic runs with zero unsafe blocks.

Policy: the converter annotates **only functions whose bodies actually contain unsafe
ops** — so the `[c_function]` count is the port-progress metric for the follow-up story:
the porting agent removes the annotation as it rewrites pointer code into safe idioms, and
the count monotonically falling to zero IS the port. The deliberate trade: blanket unsafe
erodes das's per-op audit granularity — accepted for generated modules (never hand-edited;
the annotation is the audit marker). Caveat: unsafe never propagates into lambda/generator
bodies — irrelevant, C has none.

### 5.6 Varargs (revised 2026-08-21 — discussed, pack probed)

No language-level varargs in das, none planned. Final design (Boris 2026-08-21, probed
end-to-end; normative code in lowering-examples.md): **the `[variadic]` hybrid** — the
tuple is the type-safe call ABI (`sum(4, (10, 2.5, 20, 0.5))`); a generated `apply`
prologue converts it once into a `CVaList` (3-arm variant, va-promotion decided by
folding bool typeinfo traits); the converted C body stays *mechanical* — `va_arg` is a
cursor pop, `va_copy` an array+cursor copy, forwarding passes the CVaList — no
restructuring of C consumption loops.
printf keeps a constant-format fast path in the same macro; rendering binds CRT
`snprintf` per directive (bind-first strategy, stdlib-examples.md) — byte-exact, no
hand-written conversion engine; `c_vprintf` is the same splitter at runtime. Packaging
(annotation-registered call macros vs converter-emitted per-function classes) is a P1
detail — both halves probed. FFI varargs out of scope.

Stdlib-wide consequence (Boris): every variadic libc entry gets a macro; the rest are
plain functions. The standard library is the next big discussion block after the language
families.

## 6. Converter optimization tier (the "cleaner port" pass)

Sidecar-gated, applied only after demo-sync is green — every optimization trades checks or
shape for speed while preserving semantics of *correct* programs, so correctness is proven
first, then the tier switches on. The list is a living discussion with Boris; seeded with
the obvious ones (all spellings repo-verified 2026-08-21):

| # | Optimization | Mechanism |
|---|---|---|
| O1 | Canonical counting loop → das native range loop: `for (i=0; i<n; i++) { a[i]=b; }` ⇒ `for (i in range(n)) { a[i] = b }` when `i` is unmodified in the body and `n` loop-invariant | Unlocks das's **automatic bound-check elision** (`src/ast/ast_bound_check_elision.cpp` proves range-bounded indices with no annotation) plus the interpreter's fused loop fast path |
| O2 | `[unsafe_deref]` on functions | Existing das function annotation — drops null-deref checks (interp + JIT honor it) |
| O3 | `[hint(unsafe_range_check)]` on functions where O1's provable form doesn't apply (pointer-indexed renderer inner loops) | Existing hint honored by both the interp elision pass and the JIT |
| O4 | Pointer-walk → index rewrite (`while (*p) p++` family) where the base and bound are recoverable | Feeds O1/elision; where not provable, stays pointer form under O3 |
| O5 | Byte-fill / byte-copy loop recognition → `memset` / `memcpy` builtins | Doom's renderer has several |
| O6 | Dense no-fallthrough switch → computed-`goto` jump table (bounds guard + `goto base + x`) | The matched-flag loop is the semantic default; O6 exists for hot dense dispatch (Lua VM: ~85 cases per instruction) |

Expectation (Boris, 2026-08-21): O1–O3 alone likely reach the 35 fps interp bar.

## 7. c_runtime module (the libc subset)

One das module the generated code requires. Grown demand-driven by the suites; initial set (referenced as "the §7 baseline" from the matrix):

| Area | Contents | Notes |
|---|---|---|
| memory | `malloc/free/realloc/calloc` **bound to the real CRT** via the dasCRuntime glue module (bind-first strategy, stdlib-examples.md — NOT the das heap, NOT das's aligned-alloc builtin); `memcpy/memmove/memset/memcmp` likewise | CRT-exact by construction; Doom's zone allocator = one malloc at startup |
| strings | `strlen/strcpy/strncpy/strcat/strcmp/strncmp/strchr/strstr/...` on `uint8?` | C strings are byte arrays, never das `string`; string literals become private `uint8[N]` globals (NUL-terminated, interned per module) |
| stdio | das `fio` wraps `FILE*` nearly verbatim; gaps bind via dasCRuntime; printf family = the `[variadic]` macro + per-directive CRT `snprintf` | PureDOOM routes file I/O through its callback table, so Doom mostly bypasses stdio |
| stdlib | `atoi/atol/abs/labs/exit/getenv/rand/srand` | Doom has its own `M_Random`; `rand` for suites |
| math | das math superset; exotica binds CRT libm → **bit-exact** vs native baseline | Doom is fixed-point (`FixedMul` needs an int64 intermediate — das int64 fine); Lua's number behavior native-identical for free |
| ctype | `isdigit/isalpha/toupper/...` | table-driven |

Out of scope v1 (ledgered): locale, wchar, signal, setjmp, time beyond `time/clock`,
full FILE* semantics (ungetc etc. added on suite demand).

## 8. Verification plan

### V0 — capability probes
§3's script checked in and extended (JIT/AOT goto, struct copy, multi-dim arrays, intptr
width). Every das-fact the backend relies on has a probe; runs in CI.

### V1 — c-testsuite (~220 single-file execute tests)
The CI gate from P1 on. Runner: fetch → for each `.c`: convert → run under interp → diff
against `.expected`. **Ratchet**: pass-count may only grow; every skip carries a ledger line
(feature, reason, phase that unblocks it).

### V2 — GCC c-torture `execute` (~1500 files)
Heavyweight. Import script filters GNU-isms (nested functions, `__builtin_*` beyond a shim
list, asm) into the ledger; the rest ratchets. Run interp always; JIT/AOT lanes nightly.

### V3 — csmith differential
Nightly: N seeds → `csmith | gcc -O0 -fwrapv` vs convert-and-interp, compare the checksum
output. Any divergence is a converter bug by construction; minimize with creduce. Start
after P4 (needs unions/bitfields — csmith generates them).

### V4 — Lua 5.4 milestone
Pure ANSI C ~30 kLOC, converts as a whole program, then **runs its own test suite** —
thousands of free semantic assertions — and doubles as the second perf benchmark
(fib/nbody/binary-trees under lua vs native lua).

### V5 — Doom
- **Determinism oracle**: instrument the C source (pre-conversion, so native build and
  converted build share the instrumentation for free) with a per-tic checksum —
  `players[0].mo->{x,y,z,angle,health}` + P_Random index — written to a log. Native run vs
  das run: byte-identical logs across demo1/2/3 = semantics proven. First desynced tic
  localizes the bug.
- **Perf**: `-timedemo demo3`, doom2.wad. Report realtics→fps: native `/O2` / interp / JIT /
  AOT. (AOT of converted code is C → das → C++ — full circle, worth the writeup.)
- **Frame oracle**: framebuffer CRC at fixed tics vs native (the framebuffer is CPU memory —
  fully headless, no window needed). The whole V5 lane is CI-able headless.
- **Playable**: dasImgui harness app (harness lifecycle per skill): RGBA framebuffer →
  texture blit per frame; imgui key events → `doom_key_down/up`; 11025 Hz s16 stereo PCM →
  native audio path. **Music is in the metric**: `doom_tick_midi` (140 Hz) events feed
  dasAudio's existing MIDI player (`modules/dasAudio/strudel/strudel_midi_player.das` +
  `strudel_sf2.das`, sf2/sf3 soundfonts) — zero synth work; needs only a GM soundfont in
  the harness and the event-routing glue.
- **WADs**: CI uses freedoom2.wad (BSD-licensed, fetchable); doom2.wad runs locally
  (user-supplied). Demo-sync reference logs recorded per-wad.

## 9. Phases

No sizing — order and exit criteria only.

| Phase | Work | Exit criterion |
|---|---|---|
| **P0** | Repo bootstrap (external-module skeleton, daslang-with-Clang consumed, junction/worktree pattern); probe ledger checked in; end-to-end skeleton | `int main(){return 42;}` converts, runs, exit code 42, under interp+JIT+AOT |
| **P1** | Expression/statement core: scalar types, promotions, all operators, if/while/for/do-while, functions, locals/globals, statement-ification; c_runtime seed (printf/%d, malloc); V1 online | c-testsuite ratchet climbing; scalar-only tests green |
| **P2** | Aggregates: structs (by-value semantics incl. param/return copies), fixed arrays (multi-dim, decay), pointers (arith, casts, function pointers), string literals, statics, enums; V2 online | struct/pointer/array suite sections green |
| **P3** | Control-flow completeness: goto (incl. into-nested-block flattening), switch lowerings (if-chain for sparse, computed-goto jump table for dense, state-machine for Duff), labels, fallthrough | torture control-flow section green |
| **P4** | Punning tier: unions (both policies), bitfields, fn-ptr shims, varargs/va_list, marshal-reader generator; V3 (csmith) online | csmith runs clean at N=1000/night |
| **P5** | Lua 5.4: whole-program conversion, its test suite, perf bench | Lua test suite passes under interp |
| **P6** | Doom bring-up ladder: converts+compiles → `D_DoomMain` reaches attract screen (framebuffer CRC) → demo-sync green demo1/2/3 → input playable → SFX → timedemo | demo-sync 100%, playable, perf table v1 published |
| **P7** | Perf pass: profile interp hot spots (`R_DrawColumn`/`R_DrawSpan` inner loops are the known worry), JIT/AOT lanes green on everything, final perf table; the writeup | The metric sentence in §2 is true |

## 10. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| libclang hides implicit casts / operator detail | med | We recompute conversions ourselves (needed anyway); `-ast-dump=json` hybrid fallback |
| das module acyclicity vs C's mutual references | med | Whole-program/SCC emission (§4.3) — decided, not open |
| Giant generated modules vs das compile time | med | SCC split, tables to own modules; measure at P6 before optimizing |
| `goto` broken in JIT or AOT emitters | low | Both emitters carry `ExprGoto`/`ExprLabel` handlers (source-verified); P0 three-tier gate confirms at runtime; fallback = Relooper-lite restructure pass |
| goto into nested block (C-legal, das findLabel is lexical-upward) | low | Flatten the target block into the parent scope; rare in real code |
| ~~Struct-in-struct/array copy semantics mismatch~~ | — | RESOLVED ✓: plain `=` deep-copies POD incl. fixed-array members (probed) |
| Interp too slow for playable Doom | low | 320×200@35 fps on 2026 hardware leaves ~2-3 orders headroom; JIT/AOT lanes exist regardless |
| c_runtime printf correctness long-tail | low | Standalone formatter test set imported from suite failures |
| PureDOOM deviations from vanilla break demo sync vs expectations | low | Sync is measured converted-vs-native **of the same source** — self-consistent by construction |
| GPL hygiene | low | External repo (decided); converter code MIT/BSD, `doom/` subtree GPL-2 |

## 11. Repo layout (proposal)

```
c2das/
  converter/        # the .das program: clang walk, C-IR, passes, emitter
  c_runtime/        # das module: libc subset (§6)
  probes/           # V0 capability ledger
  suites/           # fetch scripts, runners, ratchet state, skip ledgers (c-testsuite, torture, csmith)
  lua/              # vendored lua-5.4.x (MIT) + harness
  doom/             # vendored PureDOOM (GPL-2), instrumentation patch, sidecar, dasImgui harness, wads/ (freedoom2 fetched; doom2.wad local-only)
  docs/             # this plan (moved in), feature matrix, dialect spec, perf tables
```

## 12. Open questions (for Boris, one at a time)

1. ~~Repo name~~ — **`c2das`** (repo and tool), locked 2026-08-21.
2. ~~Music scope~~ — **in the metric**, via dasAudio's existing MIDI player (sf2/sf3);
   locked 2026-08-21.
3. ~~Interp perf~~ — **35 fps bar, 30 fps accepted floor**; converter optimization tier
   (§6) is the lever; locked 2026-08-21.
4. csmith nightly budget: defaulted to 1000 seeds/night (P4 exit criterion) — adjustable,
   not worth a decision round.

## 13. Core-language side-arcs (daslang repo, separate PRs — Boris 2026-08-21)

Moved to **[sidequest.md](sidequest.md)** for visibility — the full list of daslang
core-language follow-ups (`[pack(N)]`, `[align_as(N)]`, native width-bitfields, native
setjmp/longjmp, typeinfo trait macros, static_if string-folding, `[inline]` on property
operators, quiet exit). Contract unchanged: each is its own daslang arc, c2das never
blocks — every entry has a working, probed fallback.
