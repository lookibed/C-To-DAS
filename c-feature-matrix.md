# C-To-DAS — C Feature Matrix ("all shapes")

Every C99 construct → its das lowering. Status legend:
**D** direct (1:1 emission) · **L** lowered (mechanical rewrite, always applied) ·
**E** emulated (generated machinery / c_runtime) · **S** sidecar-driven (per-project policy) ·
**U** unsupported v1 (ledgered, diagnostic at convert time).

Dialect: C99, LLP64 (`int`=32, `long`=32, `long long`=64), signed overflow wraps,
left-to-right evaluation order, arithmetic `>>` on signed. Facts marked ✓ are
probe-verified 2026-08-21.

## 1. Types

| C | das | St | Notes |
|---|---|---|---|
| `char`, `signed char` | `int8` | L | arithmetic promotes to `int`, truncates on store ✓ (das forces this; identical to C promotion). Plain `char` = signed (MSVC default) |
| `unsigned char` | `uint8` | L | same promotion scheme via `uint`/`int` per C6.3 |
| `short` / `unsigned short` | `int16` / `uint16` | L | same |
| `int` / `unsigned` | `int` / `uint` | D | wrap defined both sides (das `-fwrapv`) |
| `long` / `unsigned long` | `int` / `uint` | D | LLP64 choice; sidecar can flip to 64 |
| `long long` / `unsigned long long` | `int64` / `uint64` | D | |
| `float` / `double` | `float` / `double` | D | ✓ double exists. `long double` → `double` (MSVC-compatible) |
| `_Bool` | `bool` | L | conversions to/from int made explicit |
| `enum` | **das `enum`** (always default int base) | L | readability-first (Boris 2026-08-21). Probed: `==`/`!=` direct; relational `<` needs `int()` casts (das enums have none); arithmetic & array-index sites → `int(e)`; implicit int→enum → c_runtime `enum_from_int(type<E>, i)` hiding `unsafe(reinterpret)` ✓; out-of-range values survive, compare by value, print `enum N` ✓; duplicate enumerators OK (`wp_nochange` alias pattern ✓, prints first-declared name); `int(E.COUNT)` **const-folds as fixed-array dim** ✓ (`mobjinfo[NUMMOBJTYPES]` direct); members print bare names (`B`) ✓. Flag-style enums: sidecar may demote to int constants or add generated `\|`/`&` ops |
| `T*` | `T?` | D | scaled arith ✓, diff in element units ✓, `reinterpret<U?>(p)` ✓, `intptr` round-trip ✓. Bodies with pointer ops get `[c_function]` (whole-body unsafe, plan §5.5) — no per-op `unsafe` noise. `void*`↔`T*` implicit C conversions → explicit `reinterpret`; pointer relational `< >` → `intptr` compare. Allocation model: ALL C objects live in raw memory (`c_malloc`) / globals / stack — converter never emits `new`/`delete`, das GC never involved, C manages lifetimes |
| `void*` | `void?` | D | casts via `reinterpret` |
| `T[N]` | `T[N]` fixed array | D | layout/stride/index order == C ✓ (incl. multi-dim); `int (*)[3]` row pointers map to `int[3]?` natively ✓ (scaled row arith works); negative pointer indices ✓. **Safety upgrade**: das range-checks array indexing — C OOB (UB) becomes a panic = free memory-safety oracle; sidecar demotes a flagged array to pointer access when vanilla behavior relies on the overrun |
| array initializers | full-size `fixed_array(...)` only — **no partial init**: literal size must equal the array size (probed ✗ on mismatch) | L | C `int a[6]={1,2}` → pad the literal with explicit zeros (small) or decl + assignments (das zero-inits everything = C's static zeroing, so only nonzero elements need stores); designated `[5]=x` → decl + targeted assignments; `char s[8] = "abc"` → c_runtime compile-time string→padded-`uint8[N]` macro helper (readability; P0 probe) |
| VLA `T[n]` | — | U | ledgered; none in Doom/Lua core |
| function pointer | `function<(args):ret>` | D | `@@fn` + `invoke` ✓; cross-signature puns → shim (§5.2 of plan) |
| `struct` | das `struct` (never `class`) | D | layout == clang for all natural shapes (probed: pack, nested align, tail padding, stride, 8-byte fn ptrs); `sizeof`/`offsetof`/`_Alignof` translate to das `typeinfo` forms (all native ✓); prefix punning + container_of work via `reinterpret` ✓ |
| `#pragma pack` / `__attribute__((packed/aligned))` / `_Alignas` | marshal-only type (accessors over bytes) | S | das has no packing knob; disk structs are already in the marshal domain |
| flexible array member / over-indexed trailing array (`columnofs[8]` + `malloc(sizeof+n)`) | sidecar-flagged: trailing array becomes pointer-based access (no range check) | S | das fixed-array range check would panic on the C89 over-index idiom; detection hint: `malloc(sizeof(T) + …)` sites |
| `union` | **`[c_union]` structure-annotation macro** (c_runtime): declaration lists members with their C types — C-shaped, human-readable; macro rewrites fields into one max-size, max-align `_storage` and synthesizes property operators | E | punning = memcpy semantics (C11-defined) by construction. Probed ✓: **one ref-returning operator per member** (`def operator . pt(var s) : Point&` via reinterpret of storage) covers read, write, compound, nested `u.member.field = x`, and addr-of — no get/set pairs needed (bitfields keep pairs; bits aren't addressable). Remaining P0 probe: storage alignment source (max-align member type, or `[align_as]` from plan §13). Anonymous unions flatten into parent via forwarding operators. Perf: interp pays a call per access — Lua's `TValue` will feel it (JIT/AOT inline) |
| bitfield declaration readability | **`[c_bitfields(f = width, ...)]` annotation macro** — same mechanism: C-shaped declaration, macro generates the probed backing-unit + property-operator layer | E | replaces per-type generated operator piles in the output with one annotation line |
| bitfields | backing `uintN` units at clang's allocation-unit offsets + generated **property operators** (`def operator . f` / `def operator . f :=`) | E | probed ✓: call sites read exactly like C (`s.a = 5`, `s.a += 1` — compound assign routes through get+set); signed fields sign-extend via shl/sar; wrap-on-overflow = C truncation; layout/size C-exact. Costs: `[inline]` rejected on property operators → interp pays a call per access (JIT/AOT inline); `__` names reserved → `_bits0`. Doom uses none (flags are `#define` masks) — suites/csmith pressure only. Native width-bitfields = core-language side-arc (plan §13) that would delete this layer |
| `const T` | `let` / const params | L | best-effort; correctness never depends on it |
| `volatile` | dropped + warning | L | no threads/signals in scope |
| `restrict` | dropped | L | |
| typedef | resolved (das `typedef`/alias where clean) | L | |
| incomplete/opaque struct ptr | forward-declared das struct | D | |

## 2. Declarations & storage

| C | das | St | Notes |
|---|---|---|---|
| file-scope var | module `var` global | D | TU-prefix rename for statics with name collisions. das zero-init = C ✓ |
| global initializers with addresses (`int *p = &g;`, `char *names[] = {…}`) | inline when pointee explicitly initialized & precedes (probed ✓ — das validates init dependency order); else generated `[init]` function (= load-time static init, before main ✓) | L | circular pointer globals always via `[init]`; array-of-pointers spells `T? [N]` — the space matters, `?[` lexes as the safe-index operator ✓; fn-ptr tables (`states[]`) init inline ✓ |
| `static` file-scope | module-private global | L | |
| `static` local | module global named `<fn>_<name>` — **no guards ever** | L | C99 static initializers are constant expressions by definition; load-time init = das global init |
| `extern` | resolved at whole-program link (one module / SCC) | L | plan §4.3 |
| initializers (scalar, struct, array, designated, compound literals) | `S(f = v, ...)` named-init (partial init zeroes rest = C rule ✓); arrays via `fixed_array(...)` ✓ — never `[...]` (that's a dynamic array) | L | giant const tables (`info.c`) emit as global literals (probed ✓); runtime-init fallback where literals can't express it |
| string literal | `char *p = "lit"` → `reinterpret<uint8?>("lit")` — das literal stays a literal (probed ✓: interned, static, NUL-terminated, byte-walkable); `char buf[] = "lit"` (mutable copy) → `cstr_array` byte-array global | L | write-through-literal = UB both sides (symmetric); bridge back = `reinterpret<string>(p)` ✓ (alias — read-only bridge points); printf const formats consumed at convert time |
| identifier collides with das keyword | `_c_` prefix rename | L | reserved-word list maintained with grammar |

## 3. Expressions

| C | das | St | Notes |
|---|---|---|---|
| `+ - * / %` int | direct | D | div/mod truncate toward zero ✓ = C99 |
| `+ - * / %` on char/short | compute in `int`, truncate on store | L | promotion pass ✓ |
| `<< >>` | direct; unsigned `>>` via `uint` operand | D | `-8 >> 1 = -4` ✓; shift counts masked to width (dialect) |
| `& \| ^ ~` | direct | D | |
| `&& \|\|` | direct (short-circuits) | D | side-effecting RHS after statement-ification stays correct via `if`-lowering |
| `?:` | `c ? a : b` | D | ✓ gen2; side-effecting arms → `if`-lowering |
| assignment as expression `x = (y = z)` | temp + statement sequence | L | statement-ification pass |
| compound assign `+=` etc. | direct where types match; else expanded | D/L | small-int compound → expanded promote/truncate |
| pre/post `++ --` in expressions | temp + statement sequence | L | das `++` is statement-only |
| comma operator | statement sequence + last value | L | |
| `sizeof` / `_Alignof` / `offsetof` | constant-folded at convert time (clang layout) | L | |
| casts (explicit) | das cast / `reinterpret` for pointer & pun casts | D | |
| implicit conversions | recomputed by converter, emitted explicit | L | libclang not trusted for these; plan §4.1 |
| `&x` | `addr(x)` under `unsafe` | D | ✓ |
| `*p` | `deref(p)` / auto-deref field access | D | ✓ |
| `p[i]` on pointer | `deref(p + i)` | L | ✓ scaled |
| `a[i]` on array | das index | D | |
| `s.f` / `p->f` | `.` (das auto-derefs pointers) | D | |
| function call | direct | D | |
| call through fn ptr | `invoke(fp, ...)` | D | ✓ |
| struct assignment / by-value param / by-value return | `=` for POD (probed ✓, deep copy incl. fixed-array members); by-value param = callee-side local copy (das `var` params are references, probed ✓) | L | |
| varargs call | **`[variadic]` hybrid** (Boris 2026-08-21, probed ✓ end-to-end): tuple = type-safe call ABI (`sum(4, (10, 2.5, 20, 0.5))`); generated `apply` prologue converts it ONCE to `CVaList` (variant `i:int64/d:double/p:void?`) via folding bool traits (`is_pointer`/`is_float`/`is_double`); C body stays MECHANICAL — `va_arg` = cursor `as` pop, `va_copy` = array+cursor copy, forwarding = pass the CVaList | E | printf renders via CRT `snprintf` per directive; `c_vprintf` = runtime splitter over the CVaList; trap: `typename` reflects the binding's constness (non-`var` param → `"float const"`) — string-compare it and you silently mis-branch; bool traits are qualifier-immune (sidequest: trait macros); mismatch pop = panic (C UB oracle) |
| array decay | `addr(a[0])` | L | |
| pointer compare / null | direct (`==`, `!= null`) | D | relational on pointers via `intptr` |
| int↔ptr casts | `intptr` / `reinterpret` | D | ✓ |

## 4. Statements

| C | das | St | Notes |
|---|---|---|---|
| `if` / `else` | direct | D | |
| `while` | direct | D | |
| `do { } while (c)` | first-pass flag: `var _first = true; while (_first \|\| c) { _first = false; body }` (Boris 2026-08-21, probed ✓) | L | `continue`/`break` map natively; cond never evaluated on first entry ✓; side-effecting cond → `while (true)` + tail test fallback |
| `for (init; cond; inc)` | canonical → O1 `for (i in range(n))`; general → **increment-first flag**: `init; _f=false; while (true) { if (_f) inc; _f=true; if (!cond) break; body }` (probed ✓ — `continue` runs inc, `break` skips it, both native) | L | body-block `finally { inc }` variant probed (runs per iteration + on continue ✓) but also fires on break — eligible only when no break or inc-effect dead; profile both at P1. C99 for-scope vars → bare enclosing block |
| `break` / `continue` | direct | D | C has no labeled break; nested-loop exits via goto map naturally |
| `switch` | **three-tier ladder** (Boris 2026-08-21): (1) if/elif chain when no fallthrough and breaks are tail-only — most readable, majority case; (2) matched-flag loop, fully general (probed ✓: fallthrough, mid-body break, default-anywhere, `continue`-in-switch via `_cont` epilogue); (3) O6 computed `goto var` jump table for dense hot dispatch | L | see lowering-examples.md; tier 1's C `continue` maps directly (no loop wrapper) |
| `switch` — Duff's device (case into loop body) | state-machine lowering | L | flag form can't enter mid-loop; rare — suites only |
| `goto` / labels | `goto label N` / `label N:` — labels renumbered per function, C names kept as comments | D | ✓ runtime-verified; das labels are ints, lexically scoped upward. goto over a declaration probed ✓: initializer + zero-init skipped (side effects don't run), variable indeterminate = C-exact |
| `goto` into a nested block | flatten target block into parent scope, then direct goto | L | C-legal (skips initializers); das lexical lookup can't see in — flattening restores it |
| `return` | direct (value or void) | D | struct returns get by-value clone |
| blocks / scoping | bare `{ }` blocks (gen2 lexical scope) | D | |
| `setjmp` / `longjmp` | das `try`/`recover` + panic (probed ✓ 2026-08-21): `c_longjmp` sets `_c_jmp_target`+`buf.val` then panics; each setjmp's recover intercepts only its own buf, **rethrows otherwise** ✓ (multi-level targeted jumps work; genuine panics rethrow too — target is null) | E | contained pattern (`if (setjmp==0){A}else{B}`, = Lua's `luaD_rawrunprotected`) → direct try/recover; general re-entry → trampoline loop (`while` + `_sj_run` flag); locals-after-longjmp indeterminate = C rule, re-entry values conforming. das finally skips on panic = C's no-cleanup-on-longjmp — semantics MATCH. Poetic: one das exception mode implements panic via setjmp already — hence the plan §13 side-arc: native das setjmp/longjmp "as is" (rides with `[pack()]`), which would delete this protocol. Lua `pcall` fully works at P5 (`LUAI_THROW`→`c_longjmp`) |

## 5. Functions

| C | das | St | Notes |
|---|---|---|---|
| definitions / prototypes | `def` in whole-program module | D | |
| recursion | direct | D | |
| K&R-style params | libclang normalizes | D | |
| `static` functions | module-private, TU-prefixed on collision | L | |
| `inline` | dropped (das inlines separately) | L | |
| varargs callee (`va_list`, `va_start/arg/end`) | extra `array<CVal>` param; `va_arg` pops typed | E | plan §5.5 |
| `main(argc, argv)` | harness synthesizes argv as `uint8?` array from das args | E | c_runtime |
| `exit(code)` mid-stack | das `exit(code)` 1:1 (daslib/fio, unsafe — free under `[c_function]`); probed ✓ from deep stack, process code propagates | D | `c_exit` wrapper adds C's atexit-handler run + stdio flush; `c_abort()` → `exit(3)` (MSVC baseline match); runner prints exit diagnostics — harness diffs stdout only (P1: confirm stderr routing) |

## 6. Preprocessor

Handled entirely by clang (converter sees post-expansion AST). Consequences:

| Aspect | Handling |
|---|---|
| `#define` constants/macros | expanded — output shows values; readability recovery is out of scope for the pipeline (locked decision) |
| `#include` | dissolved into the whole-program TU set |
| `#if` platform selects | converter runs clang with fixed defines from sidecar (e.g. PureDOOM's `DOOM_IMPLEMENTATION`) |
| `__FILE__/__LINE__` | expanded by clang — correct automatically |

## 7. libc surface (per target, grown demand-driven)

| Target | Needs beyond plan §7 baseline |
|---|---|
| c-testsuite | `printf` core formats; little else |
| gcc torture execute | `abort/exit`, `memcpy/memset/strcmp/strlen`, occasional `printf`; GNU builtins shim list (`__builtin_abs` etc.) or ledger |
| csmith | `printf` checksum output only (csmith is self-contained by design) |
| Lua 5.4 | broadest: full `string.h`, `stdio` incl. `fgets/fputs/ferror/tmpfile*`, `stdlib` incl. `strtod/realloc`, `math.h`, `time/clock`, `locale` stubs (C locale fixed) |
| PureDOOM | almost nothing — I/O, alloc, time, print all route through its callback table, implemented natively in das harness |

## 8. Deliberately out of scope (v1 ledger)

VLAs · `_Complex` · `_Atomic` / threads · signals · wide chars/locale ·
inline asm · GNU nested functions & statement-exprs (torture ledger) ·
FFI varargs · `long double` extended precision.
(`alloca` moved to supported 2026-08-21 — C-stack arena, stdlib-examples.md.)
