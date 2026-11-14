# C-To-DAS — C Feature Matrix ("all shapes")

Every C99 construct → its das lowering. Status legend:
**D** direct (1:1 emission) · **L** lowered (mechanical rewrite, always applied) ·
**E** emulated (generated machinery / c_runtime) · **S** sidecar-driven (per-project policy) ·
**U** unsupported v1 (ledgered, diagnostic at convert time).

Dialect: C99, LLP64 (`int`=32, `long`=32, `long long`=64), signed overflow wraps,
left-to-right evaluation order, arithmetic `>>` on signed. Facts marked ✓ are
probe-verified 2026-08-21.

Corrections tagged **(F*n*)** were re-probed on daScript `6401904cf9` (2026-11-14); the tag is a
plain label. A ✓ that the re-probe did not bear out is corrected in place and tagged. Where the
translator emits a different shape on purpose, the text says what it emits and why.
## 1. Types

| C | das | St | Notes |
|---|---|---|---|
| `signed char` | `int8` | L | arithmetic promotes to `int`, truncates on store ✓ (das forces this; identical to C promotion) |
| `char`, `unsigned char` | `uint8` | L | same promotion scheme via `uint`/`int` per C6.3. Plain `char` = **unsigned** (F17): `char` as `int8` and a C string as `uint8?` cannot coexist (`char *p = "x"` is "can only copy compatible type; int8?& = uint8?", and every string crossing to `crt` would need a reinterpret), so the translator fixes the dialect: the dumper passes `-funsigned-char`, both targets carry `char_signed: false`, and the native baseline compiles with the same flag |
| `short` / `unsigned short` | `int16` / `uint16` | L | same |
| `int` / `unsigned` | `int` / `uint` | D | wrap defined both sides (das `-fwrapv`) |
| `long` / `unsigned long` | `int` / `uint` | D | LLP64 choice; sidecar can flip to 64 |
| `long long` / `unsigned long long` | `int64` / `uint64` | D | |
| `float` / `double` | `float` / `double` | D | ✓ double exists. `long double` → `double` (MSVC-compatible) |
| `_Bool` | `bool` | L | conversions to/from int made explicit |
| `enum` | **das `enum`** (always default int base) | L | readability-first (Boris 2026-08-21). Probed: `==`/`!=` direct; relational `<` needs `int()` casts (das enums have none); arithmetic & array-index sites → `int(e)`; implicit int→enum → c_runtime `enum_from_int(type<E>, i)` hiding `unsafe(reinterpret)` ✓; out-of-range values survive, compare by value, print `enum N` ✓; duplicate enumerators OK (`wp_nochange` alias pattern ✓, prints first-declared name); `int(E.COUNT)` **const-folds as fixed-array dim** ✓ (`mobjinfo[NUMMOBJTYPES]` direct); members print bare names (`B`) ✓. Flag-style enums: sidecar may demote to int constants or add generated `\|`/`&` ops. Under the `linux` host dialect clang gives an enum without a negative enumerator the underlying type `unsigned int`; the C-IR marks it `"signed": false` and the relational compare goes through `uint` (F22). An enum converts to `uint`, `int64`, `uint64` and the 8- and 16-bit integers directly, with the bits `int(e)` gives; `float(e)` is error 30341 (F106) |
| `T*` | `T?` | D | scaled arith ✓ (`p - n` takes a pointer **variable** only: `addr(buf[0]) + 10 - n` is "no matching functions or generics: i_das_ptr_sub", so a computed pointer less a count is spelled `ptr + -(n)`; F59), diff in element units ✓, `reinterpret<U?>(p)` ✓, `intptr` round-trip ✓. Bodies with pointer ops get `[c_function]` (whole-body unsafe, plan §5.5) — no per-op `unsafe` noise. `void*`↔`T*` implicit C conversions → explicit `reinterpret`; pointer relational `< >` → `intptr` compare, and `==`/`!=` between two data pointers too (F44, row "pointer compare / null"). Allocation model: ALL C objects live in raw memory (`c_malloc`) / globals / stack — converter never emits `new`/`delete`, das GC never involved, C manages lifetimes |
| `void*` | `void?` | D | casts via `reinterpret` |
| `T[N]` | `T[N]` fixed array | D | layout/stride/index order == C ✓ (incl. multi-dim); `int (*)[3]` row pointers map to `int[3]?` natively ✓ (scaled row arith works); negative pointer indices ✓. **Safety upgrade**: das range-checks array indexing — C OOB (UB) becomes a panic = free memory-safety oracle; sidecar demotes a flagged array to pointer access when vanilla behavior relies on the overrun. An index must be `int`, `int64`, `uint` or `uint64` (error 30184 otherwise), so a `char` or `short` subscript widens to `int` (F43). `addr(a[N])`, C's defined one-past-the-end address, trips the range check ("index out of range, 3 of 3"): it is spelled `addr(a[0]) + N`, and `addr(a[0]) + end_index(k, N)` (c_runtime `c_bounds`) for a run-time `k` that can reach the length (F45) |
| array initializers | full-size `fixed_array(...)` only — **no partial init**: literal size must equal the array size (probed ✗ on mismatch) | L | C `int a[6]={1,2}` → pad the literal with explicit zeros (small) or decl + assignments (das zero-inits everything = C's static zeroing, so only nonzero elements need stores); designated `[5]=x` → decl + targeted assignments; `char s[8] = "abc"` → c_runtime compile-time string→padded-`uint8[N]` macro helper (readability; P0 probe). An array of data pointers names its element type, `fixed_array<T?>(...)`: an all-`null` literal infers `void?[N]`, which a `T? [N]` refuses (F41) |
| VLA `T[n]` | — | U | ledgered; none in Doom/Lua core |
| function pointer | `function<(args):ret>` | D | `@@fn` + `invoke` ✓. A parameter's constness is part of a das function type (its name is not), so one C function-pointer type takes `var` at every data-pointer position and every function of that signature declares them `var` (F34). Cross-signature puns (`actionf_t`) need **no shim** (F32): a das function value is 8 bytes and `reinterpret` between function types is lossless under the interpreter and the JIT, while a variant dispatching on the member last stored calls Doom's `A_WeaponReady` with one argument where C passes two; a union of function pointers is a `[c_union]` like any other (§5.2 of plan) |
| `struct` | das `struct` (never `class`) | D | layout == clang for all natural shapes (probed: pack, nested align, tail padding, stride, 8-byte fn ptrs); `sizeof`/`offsetof`/`_Alignof` translate to das `typeinfo` forms (all native ✓), with two exceptions: `offsetof` of a `[c_union]` member is the constant 0 (the member is an operator over the storage, not a field; F31), and `_Alignof` of a record das aligns below clang (F5), of a marshal-only record or of a `va_list` is clang's value as a literal (F54); prefix punning + container_of work via `reinterpret` ✓ |
| `#pragma pack` / `__attribute__((packed/aligned))` / `_Alignas` | marshal-only type (accessors over bytes) where das cannot place the fields | S | das has no packing knob; disk structs are already in the marshal domain. The translator lifts the rule where the layout allows (F51): a packed or `pack(n)` record whose plain fields each sit at a multiple of their das alignment converts as an ordinary struct through byte units and `_pad<N> : uint8[n]` padding (`[c_bitfields(_bits0 = "uint8", a = 3, _bits1 = "uint8[3]", b = 20)]`, size 5); a plain field off its das alignment (`packed { char c; int n; }`), or a das alignment past clang's, stays marshal-only |
| flexible array member / over-indexed trailing array (`columnofs[8]` + `malloc(sizeof+n)`) | C89 over-indexed `T a[N]`: sidecar-flagged (`over_indexed`: `Record.field`), trailing array becomes pointer-based access (no range check). C99 flexible member `T a[];`: no flag, the record leaves the member out and its decay is `reinterpret<T?>(reinterpret<uint8?>(p) + off)` at clang's offset | S / L | das fixed-array range check would panic on the C89 over-index idiom; detection hint: `malloc(sizeof(T) + …)` sites. A flexible member has no fixed-length das array to range-check, so it needs no sidecar entry; it fails closed when leaving it out changes the record's size or alignment (F57) |
| `union` | **`[c_union]` structure-annotation macro** (c_runtime): declaration lists members with their C types — C-shaped, human-readable; macro rewrites fields into one max-size, max-align `_storage` and synthesizes property operators | E | punning = memcpy semantics (C11-defined) by construction. Probed ✓: a ref-returning operator per member (`def operator . pt(var s) : Point&` via reinterpret of storage) covers read, write, compound, `++`/`--`, nested `u.member.field = x`, and addr-of — no get/set pairs needed (bitfields keep pairs; bits aren't addressable). Re-probed (F28): that operator does not match a **const** base (a union read through a `let` parameter is `field 'i' not found in U const`), so the macro adds a second operator per member over a const union, returning the value; das picks by the base's constness with no ambiguity. Storage alignment, probed (F27): `_storage` is `U[k]`, `U` the unsigned type of the alignment; a structure annotation's `apply` runs before inference (a struct declared later is still an alias there, an enum-constant dimension unfolded), so where the members do not give the numbers the converter states them, `[c_union(size = 4, align = 4)]`; past align 8 no unsigned type aligns. A struct literal cannot name a member, so a union initializer is the declaration plus a store. Anonymous unions: the translator does not flatten them; the member is an explicit field `_anon<N>` and `s.i` is spelled `s._anon1.i`, the path clang's `MemberExpr` chain takes (F29); forwarding operators stay a readability rewrite. Perf: interp pays a call per access — Lua's `TValue` will feel it (JIT/AOT inline) |
| bitfield declaration readability | **`[c_bitfields(f = width, ...)]` annotation macro** — same mechanism: C-shaped declaration, macro generates the probed backing-unit + property-operator layer | E | replaces per-type generated operator piles in the output with one annotation line. Widths alone do not say where clang's units start, so the macro reads its arguments in order: `_bits<N> = "uint8"` opens a unit, `_<K> = n` skips `n` bits (unnamed `:N`, the gap `:0` leaves), `name = width` places a field; with no unit open a field opens one sized by its own type, which is this row's bare form, exact under the MSVC ABI (F25) |
| bitfields | backing `uintN` units at clang's allocation-unit offsets + generated **property operators** (`def operator . f` / `def operator . f :=`) | E | probed ✓: reads, stores and compound stores read exactly like C (`s.a = 5`, `s.a += 1` — compound assign routes through get+set); `++`/`--` do not: das rejects them on a property ("can't be applied to non reference"), so `s.a++` is spelled `s.a += 1u` (F26); signed fields sign-extend via shl/sar; wrap-on-overflow = C truncation; layout/size C-exact under the MSVC ABI. Under the Itanium ABI clang packs a unit to the bytes used while the declared type still aligns the struct (`struct BF { unsigned a : 3; int b : 5; short e; }`: `e` at byte 2, size 4, align 4), which no das spelling gives: the unit width follows the C-IR bit offsets and the das alignment stays 2 (F5). Costs: `[inline]` rejected on property operators → interp pays a call per access (JIT/AOT inline); `__` names reserved → `_bits0`. Doom uses none (flags are `#define` masks) — suites/csmith pressure only. Native width-bitfields = core-language side-arc (plan §13) that would delete this layer |
| `const T` | never spelled on a pointer: `T *p`, `const T *p` and `T * const p` are each `var p : T?` | L | F3, F46: a non-`var` parameter `p : T?` is `T? const` and a local copy of it has a const pointee, so a write through it is "can't write to a constant value", it does not return as `T?` (error 30343) and does not pass to a `var` position. The const is never reinterpreted away: upstream's ruling is that the declared type is the contract the optimizer reads (writes through a stripped const were dead-code-eliminated) |
| `volatile` | `c_volatile_load(x)` / `c_volatile_store(x, v)` (c_runtime) | E | not droppable (F65; F91): the JIT, the exe and the AOT host fold a plain read of a global out of a loop that stores nothing, so a dropped `volatile` changes what the program does (a volatile loop bound becomes a constant trip count, a volatile sink store per pass is no store). The dumper marks a volatile lvalue `"vol": true`, the emitter spells its accesses through c_runtime; a whole volatile record copied at once keeps the plain copy |
| `restrict` | dropped | L | |
| typedef | resolved (das `typedef`/alias where clean) | L | |
| incomplete/opaque struct ptr | forward-declared das struct | D | |

## 2. Declarations & storage

| C | das | St | Notes |
|---|---|---|---|
| file-scope var | module `var` global | D | TU-prefix rename for statics with name collisions. das zero-init = C ✓ |
| global initializers with addresses (`int *p = &g;`, `char *names[] = {…}`) | inline when pointee explicitly initialized & precedes (probed ✓ — das validates init dependency order); else generated `[init]` function (= load-time static init, before main ✓) | L | circular pointer globals always via `[init]`; array-of-pointers spells `T? [N]` — the space matters, `?[` lexes as the safe-index operator ✓; fn-ptr tables (`states[]`) init inline ✓ unless a function in the table reaches the table back: an initializer depends on every global and function it names and, transitively, on what their bodies reach, and a path back to the global is error 31104 "global variable initialization loop" (PureDOOM's menu tables); such an initializer is assigned in `[init]` (F79). An address under `+` in a global initializer takes its own `unsafe`: `unsafe(unsafe(addr(a[0])) + 3)` (F48) |
| `static` file-scope | module-private global | L | |
| `static` local | module global named `<fn>_<name>` — **no guards ever** | L | C99 static initializers are constant expressions by definition; load-time init = das global init. Two static locals of one name in one function (sibling blocks) hoist as `<fn>_<name>` and `<fn>_<name>1` (F47) |
| `extern` | resolved at whole-program link (one module / SCC) | L | plan §4.3 |
| initializers (scalar, struct, array, designated, compound literals) | `S(f = v, ...)` named-init (partial init zeroes rest = C rule ✓); arrays via `fixed_array(...)` ✓ — never `[...]` (that's a dynamic array) | L | giant const tables (`info.c`) emit as global literals (probed ✓); runtime-init fallback where literals can't express it |
| string literal | `char *p = "lit"` → `reinterpret<uint8?>("lit")` — das literal stays a literal (probed ✓: interned, static, NUL-terminated, byte-walkable; except `""`: the empty das literal is a **null pointer**, so C's `""` gets one byte of storage, `cstr_array("", 1)`; F10); `char buf[] = "lit"` (mutable copy) → `cstr_array` byte-array global | L | write-through-literal = UB both sides (symmetric); bridge back = `reinterpret<string>(p)` ✓ (alias — read-only bridge points); printf const formats consumed at convert time |
| identifier collides with das keyword | `_c_` prefix rename | L | reserved-word list maintained with grammar |

## 3. Expressions

| C | das | St | Notes |
|---|---|---|---|
| `+ - * / %` int | direct | D | div/mod truncate toward zero ✓ = C99 |
| `+ - * / %` on char/short | compute in `int`, truncate on store | L | promotion pass ✓ |
| `<< >>` | direct, the count cast to the promoted left side's type; unsigned `>>` via `uint` operand | L | `-8 >> 1 = -4` ✓; shift counts masked to width (dialect). das defines `<<` and `>>` only for a count of the shifted value's own type (`int << uint` and `int64 >> int` are error 30406), while C promotes the count apart from the left side (F40) |
| `& \| ^ ~` | direct | D | |
| `&& \|\|` | direct (short-circuits) | D | side-effecting RHS after statement-ification stays correct via `if`-lowering |
| `?:` | `c ? a : b` | D | ✓ gen2; das evaluates only the taken arm, so calls in the arms stay inline (F18); only an arm carrying hoisted statements (an assignment or a step) takes the `if`-lowering |
| assignment as expression `x = (y = z)` | temp + statement sequence | L | statement-ification pass |
| compound assign `+=` etc. | direct where types match; else expanded | D/L | small-int compound → expanded promote/truncate |
| pre/post `++ --` in expressions | temp + statement sequence | L | das `++` is statement-only |
| comma operator | statement sequence + last value | L | |
| `sizeof` / `_Alignof` / `offsetof` | constant-folded at convert time (clang layout) | L | |
| casts (explicit) | das cast / `reinterpret` for pointer & pun casts | D | |
| implicit conversions | recomputed by converter, emitted explicit | L | libclang not trusted for these; plan §4.1 |
| `&x` | `addr(x)` under `unsafe` | D | ✓ |
| `*p` | `*p` (the node `deref(p)` is) / auto-deref field access | D | ✓ (F102); das reads `*q++` as `(*q)++`, so C's `*q++` keeps its hoisted step |
| `p[i]` on pointer | `p[i]` | D | ✓ scaled; das's pointer index takes an `int`, `uint`, `int64` or `uint64`, a negative one included, and reaches the element `deref(p + i)` does in one node (F100) |
| `a[i]` on array | das index | D | |
| `s.f` / `p->f` | `.` (das auto-derefs pointers) | D | |
| function call | direct | D | |
| call through fn ptr | `invoke(fp, ...)` | D | ✓ |
| struct assignment / by-value param / by-value return | `=` for POD (probed ✓, deep copy incl. fixed-array members); by-value param = callee-side local copy (das `var` params are references, probed ✓) | L | the copy is made for **every** record parameter, written or not: a `let` record parameter is the caller's object too, and a write through another pointer during the call shows through it (`f(a, &a)` returned 5 where C returns 1; F50) |
| varargs call | **`[variadic]` hybrid** (Boris 2026-08-21, probed ✓ end-to-end): tuple = type-safe call ABI (`sum(4, (10, 2.5, 20, 0.5))`); generated `apply` prologue converts it ONCE to `CVaList` (variant `i:int64/d:double/p:void?`) via folding bool traits (`is_pointer`/`is_float`/`is_double`); C body stays MECHANICAL — `va_arg` = cursor `as` pop. A `va_list` is c_runtime's `CVaCursor { list : CVaList const?; at : int }`, not an inline `int`: a C `va_list` travels, a callee's pops advance the caller's list. `va_start` = `v = va_begin(va)`, `va_copy` = plain assignment of the cursor, forwarding = `va_rest(ap)`, the arguments from the cursor on (F35, F36). A call of a variadic function of the same module is spelled ``f`va(fixed…, (t1, t2))``: the call macro is registered only after the parser has read the definition, so a C-spelled call above or inside it does not resolve (F37) | E | printf renders via CRT `snprintf` per directive; `c_vprintf` = runtime splitter over the CVaList; trap: `typename` reflects the binding's constness (non-`var` param → `"float const"`) — string-compare it and you silently mis-branch; bool traits are qualifier-immune (sidequest: trait macros); `bool` (no `int64(bool)`) and function values (`is_pointer` does not take them) have arms of their own (F4, F38); mismatch pop = panic (C UB oracle) |
| array decay | `addr(a[0])` | L | |
| pointer compare / null | against a null constant direct (`== null`, `!= null`); between two data pointers `intptr(p) == intptr(q)` | L | `==` between `int const?` and `int?` is error 30262 ("operations on incompatible pointers are prohibited"; F44); relational on pointers via `intptr` |
| int↔ptr casts | `intptr` / `reinterpret` | D | ✓ |

## 4. Statements

| C | das | St | Notes |
|---|---|---|---|
| `if` / `else` | direct | D | |
| `while` | direct | D | |
| `do { } while (c)` | first-pass flag: `var _first = true; while (_first \|\| c) { _first = false; body }` (Boris 2026-08-21, probed ✓) | L | `continue`/`break` map natively; cond never evaluated on first entry ✓; side-effecting cond → `while (true)` + tail test fallback |
| `for (init; cond; inc)` | four shapes, the first that applies (ruling 2026-11-01 (13), F66, `lowering-examples.md` "General for"): canonical counting loop → O1 `for (i in range(n))` (default; `--loops while` opts out); a body without `continue` → trailing increment `init; while (cond) { body; inc }`; a `continue` that never leaves the loop → `while (cond) { { body } finally { inc } }`; otherwise the **increment-first flag** `init; _f=false; while (true) { if (_f) inc; _f=true; if (!cond) break; body }` (probed ✓ — `continue` runs inc, `break` skips it, both native) | L | measured: range loop fastest under the interpreter, then trailing increment, `finally`, flag; the JIT compiles all four alike. C99 for-scope vars → bare enclosing block |
| `break` / `continue` | direct | D | C has no labeled break; nested-loop exits via goto map naturally |
| `switch` | **three-tier ladder** (Boris 2026-08-21): (1) if/elif chain when no fallthrough and breaks are tail-only — most readable, majority case; (2) matched-flag loop, fully general (probed ✓: fallthrough, mid-body break, default-anywhere, `continue`-in-switch via `_cont` epilogue); (3) O6 computed `goto var` jump table for dense hot dispatch | L | see lowering-examples.md; tier 1's C `continue` maps directly (no loop wrapper). The translator prints tiers 1 and 2 as c_runtime's call macro `c_switch (c) { case (A, B) { } case (_) { } }`, whose expansion is the spelled tiers' nodes in the same order (F105). A declaration at the switch body's own level that a later group names is declared before the lowered switch (F53); a `goto` into another case re-dispatches the switch through a `_gotoN` variable (F60) |
| `switch` — Duff's device (case into loop body) | state-machine lowering | L | flag form can't enter mid-loop; rare — suites only |
| `goto` / labels | `goto label N` / `label N:` — labels renumbered per function, C names kept as comments | D | ✓ runtime-verified; das labels are ints, lexically scoped upward. goto over a declaration probed ✓: initializer + zero-init skipped (side effects don't run), variable indeterminate = C-exact |
| `goto` into a nested block | flatten target block into parent scope, then direct goto | L | C-legal (skips initializers); das lexical lookup can't see in — flattening restores it |
| `return` | direct (value or void) | D | struct returns get by-value clone |
| blocks / scoping | bare `{ }` blocks (gen2 lexical scope) | D / L | das refuses a local that shadows a local or parameter of an enclosing scope (error 30704, the discard `_` included; sibling blocks may reuse a name), which C allows: the emitter renames a hiding local and every reference C resolves to it to the first free numbered name (F42) |
| `setjmp` / `longjmp` | das `try`/`recover` + panic (probed ✓ 2026-08-21): `c_longjmp` sets `_c_jmp_target`+`buf.val` then panics; each setjmp's recover intercepts only its own buf, **rethrows otherwise** ✓ (multi-level targeted jumps work; genuine panics rethrow too — target is null) | E | contained pattern (`if (setjmp==0){A}else{B}`, = Lua's `luaD_rawrunprotected`) → direct try/recover; general re-entry → trampoline loop (`while` + `_sj_run` flag), for the uses ISO C 7.13.1.1 allows (the whole expression statement, `!setjmp(…)`, a compare with an integer constant, a whole controlling expression) plus a store of the whole value and `return setjmp(buf)`; any other read of the value fails closed, since the trampoline reruns the site's whole statement and an operand read before the call would be read again (F58); locals-after-longjmp indeterminate = C rule, re-entry values conforming. das finally skips on panic = C's no-cleanup-on-longjmp — semantics MATCH. Poetic: one das exception mode implements panic via setjmp already — hence the plan §13 side-arc: native das setjmp/longjmp "as is" (rides with `[pack()]`), which would delete this protocol. Lua `pcall` fully works at P5 (`LUAI_THROW`→`c_longjmp`) |

## 5. Functions

| C | das | St | Notes |
|---|---|---|---|
| definitions / prototypes | `def` in whole-program module | D | |
| recursion | direct | D | |
| K&R-style params | parameter declared at its promoted type as `<name>_in`, converted on entry (`let b = uint8(b_in)`) | L | clang types a K&R definition by its promoted parameters (`int (int, int)` for `int a; char b;`) while each `ParmVarDecl` keeps its declared type, and a call passes the promoted arguments: `def knr(a : int; b : uint8)` is "no matching function" at `knr(4, 2)` (F55) |
| `static` functions | module-private, TU-prefixed on collision | L | |
| `inline` | dropped (das inlines separately) | L | |
| varargs callee (`va_list`, `va_start/arg/end`) | extra `array<CVal>` param; a `va_list` variable is a `CVaCursor` over it; `va_arg` pops typed | E | plan §5.6; a function taking a `va_list` takes the cursor, `var` so its pops advance the caller's (F35) |
| `main(argc, argv)` | harness synthesizes argv as `uint8?` array from das args | E | c_runtime. `argv[0]` has no das source that is the same on every tier, so the wrapper passes the C file's stem, `c_runtime_init("<stem>")`; the program's own arguments are `get_user_args` (after `--`); the wrapper ends in `return c_main(c_argc(), c_argv())` (F56) |
| `exit(code)` mid-stack | `c_exit(code)`, ending in das `exit_now(code)` (daslib/fio, unsafe — free under `[c_function]`) | E | `c_exit` runs C's atexit handlers, flushes stdio, then `exit_now`; `c_abort()` → `exit_now(3)` (MSVC baseline match). Re-probed on `6401904cf9` (F1): das `exit(code)` from a deep stack does propagate the process code, but prints `exit(N) called from …` and the call stack on **stdout** (upstream's design, PR #3523), so a harness that diffs stdout is not shielded; `exit_now` is quiet and keeps the code; `return N` from `main` sets the exit code too |

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
inline asm (except the empty-template compiler barrier `asm("")` / `asm volatile("" ::: "memory")`, which dumps as the null statement; F74) · GNU nested functions & statement-exprs (torture ledger) ·
FFI varargs · `long double` extended precision.
(`alloca` moved to supported 2026-08-21 — C-stack arena, stdlib-examples.md.)
