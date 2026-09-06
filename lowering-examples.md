# C-To-DAS — Lowering Examples (normative)

For every **discussed** C construct: the exact das code the converter is expected to emit.
This file is the emitter's golden reference — when converter output and this file disagree,
one of them is a bug to resolve deliberately. Families are added here only after their
discussion round; undiscussed families are absent, not implied.

Markers: **✓** = probe-verified on the in-tree binary (2026-08-21). **(P: …)** = expected
shape, named probe still owed. House rules for output: gen2, `options indenting = 4`,
formatter-run, lint relaxed (generated banner), das `struct` never `class`, C names
preserved (renamed only on keyword/static collision).

## Scalars, promotions & conversions ✓ (all probed)

### Integer promotion (char/short arithmetic)
```c
char b = 127;
b = b + 1;                 /* promotes to int, truncates on store: -128 */
```
```das
var b : int8 = int8(127)
b = int8(int(b) + 1)       // -128 ✓ — das has no small-int arithmetic; the forced shape IS C's rule
```
`unsigned char`/`short`/`unsigned short` identically via `uint`/`int`. Compound assigns on
small ints expand the same way (`b += x` → `b = int8(int(b) + x)`).

### Usual arithmetic conversions (converter-computed, explicit casts)
```c
unsigned u; int i;
if (i < u) ...             /* i converts to unsigned */
long long m = i * 10LL;    /* i widens */
```
```das
if (uint(i) < u) {
}
var m : int64 = int64(i) * 10l
```
The converter implements C6.3 itself and emits every conversion explicitly — clang's
implicit-cast nodes are never trusted (libclang exposes them poorly anyway).

### Semantics that match with NO shim (probed)
| C | das | probed |
|---|---|---|
| `-7 / 2 == -3`, `-7 % 2 == -1` (trunc toward zero) | identical | ✓ |
| `x >> 1` arithmetic on signed, logical on unsigned | identical (`uint` operand = logical) | ✓ |
| `(int)2.9 == 2`, `(int)-2.9 == -2` (trunc toward zero) | `int(2.9f)`, `int(-2.9lf)` identical | ✓ |
| `(int)i64` truncates mod 2^32 | `int(big)` identical | ✓ |
| `(unsigned)-1 == 0xFFFFFFFF` | `uint(-1)` identical | ✓ |
| signed overflow wraps (dialect: `-fwrapv` both sides) | identical | ✓ |
| `'a'` char literal is `int` | das char literals are `int` | grammar |
| shift counts ≥ width | hardware behavior both sides (x86 mask), no mask emitted | dialect |

### Floats, _Bool, ternary
```c
double d = 1.5; float f = 0.5f;
d = d * f;                 /* f promotes to double */
_Bool ok = n;              /* != 0 */
int x = ok;
m = a > b ? a : b;
```
```das
var d : double = 1.5lf
var f = 0.5f
d = d * double(f)          // ✓
var ok : bool = n != 0
var x = ok ? 1 : 0         // ✓ bool never silently int
m = a > b ? a : b          // ✓ ternary native
```

## Expressions with side effects (statement-ification)

Evaluation order fixed left-to-right (dialect; C leaves it unspecified — csmith-safe
programs don't depend on it). Temps are `_t0, _t1, …` scoped per statement. Expression
tier is otherwise "as-is or casts" (Boris) — only these shapes transform:

```c
if ((c = getch()) != EOF) ...      /* assignment as expression */
a[i++] = *p++;                     /* post-inc in expressions */
x = cond ? f() : g();              /* side-effecting ternary arms */
if (p && p->refresh(p)) ...        /* short-circuit with effects: stays native — das && short-circuits */
for (i = 0, j = n; ...)            /* comma: statement sequence (see Loops) */
```
```das
c = getch()
if (c != EOF) {
}

let _t0 = deref(p)
p = p + 1
a[i] = _t0
i++                                // das ++ is statement-only ✓ (used throughout probes)

var _t1 : int
if (cond) {
    _t1 = f()
} else {
    _t1 = g()
}
x = _t1

if (p != null && p.refresh(p)) {   // pure/short-circuit chains stay expressions ✓
}
```

## Casts — the complete emission table ✓

| C cast | das emission | probed |
|---|---|---|
| numeric ↔ numeric | workhorse cast `int(x)`, `uint(x)`, `double(x)`, … | ✓ |
| `(T *)v` any pointer↔pointer | `reinterpret<T?>(v)` | ✓ |
| `(void *)p` / `(T *)vp` | `reinterpret<void?>(p)` / `reinterpret<T?>(vp)` — C's implicit both ways becomes explicit | design |
| `(intptr_t)p` / `(T *)n` | `intptr(p)` / `reinterpret<T?>(n)` | ✓ |
| enum → int | `int(e)` | ✓ |
| int → enum | `enum_from_int(type<E>, i)` (c_runtime) | ✓ |
| int ↔ bool | `x != 0` / `b ? 1 : 0` | ✓ |
| fn-ptr ↔ fn-ptr (same signature) | direct | ✓ |
| fn-ptr across signatures (`actionf_t`) | sidecar dispatch shim (plan §5.2) | design |

## goto / labels ✓ (all probed)

```c
retry:
    if (!try_lock()) { backoff(); goto retry; }
    ...
    if (err) goto fail;
    return 0;
fail:
    cleanup();
    return -1;
```
```das
label 1:  // retry
if (!try_lock()) {
    backoff()
    goto label 1
}
...
if (err != 0) {
    goto label 2
}
return 0
label 2:  // fail
cleanup()
return -1
```
- das labels are per-function integers, converter-allocated; C label names survive as
  `// name` comments.
- Backward and forward jumps ✓; computed `goto expr` exists (jump to label numbered by an
  int expression) — used by switch tier 3.
- **goto over a declaration** ✓ probed: the initializer (and even das's zero-init) is
  skipped — side effects don't run, the variable is indeterminate. That is exactly C's
  semantics (reading it is UB in C too).
- goto INTO a nested block: das label lookup is lexical-upward — converter flattens the
  target block into the parent scope first. goto into a loop body (Duff): switch
  state-machine fallback only.

## Functions — declaration shapes

```c
static void helper(void) {}        /* internal linkage */
inline int sq(int x) { ... }
int cmp(const void *a, const void *b);   /* K&R already normalized by clang */
int main(int argc, char **argv) { ... }
```
```das
def private helper {}              // statics = private; renamed `<tu>_helper` only on cross-TU collision
def sq(x : int) : int {}           // `inline` dropped — das inlines on its own
def cmp(a, b : void?) : int {}
[export]
def main {                         // synthesized wrapper
    c_runtime_init()               // argv build, stdio setup
    let rc = c_main(c_argc(), c_argv())
    c_exit(rc)                     // runs atexit list + flushes, then das exit ✓
}
```
Local statics = module globals named `<fn>_<name>` (C99 statics have constant
initializers — no guards, ever). Struct params/returns: see Structs. Variadic: see
Variadics. Pointer-heavy bodies get `[c_function]`.

## Strings & literals

```c
const char *msg = "hello";        /* immutable literal pointer */
char buf[16] = "abc";             /* mutable array copy */
strcpy(buf, msg);
if (s[0] == 'A') ...
```
```das
var msg : uint8? = unsafe(reinterpret<uint8?>("hello"))  // ✓ probed: das literals are legal
                                                          // read-only C strings (interned, static,
                                                          // NUL-terminated); write-through = UB both sides
var buf : uint8[16] = cstr_array("abc", 16)               // byte-array globals ONLY for mutable char[] inits
                                                          // (P: compile-time macro — bytes + NUL + escapes)
strcpy(addr(buf[0]), msg)                                 // mutating string.h binds CRT (dasCRuntime)
if (int(s[0]) == 'A') {                                   // char literals are int both sides ✓
}
```
C strings are mutable `uint8` memory; the bridge back is `reinterpret<string>(p)` ✓ probed
(print/length/content-`==` work on NUL-terminated buffers; alias not copy — read-only
bridge points only). Wide strings: out of scope (dialect).

## Preprocessor artifacts

```c
#define MF_SHOOTABLE 4
#define VERSION "1.9"
#define MAXOF(a,b) ((a) > (b) ? (a) : (b))
if (mo->flags & MF_SHOOTABLE) ...
```
```das
let MF_SHOOTABLE = 4               // recovered object-like constant (readable-first)
// VERSION participates via its _str_N literal
if ((mo.flags & MF_SHOOTABLE) != 0) {
}
// MAXOF call sites appear expanded: (a > b ? a : b) — function-like macros stay expanded
```
clang hands us post-expansion ASTs; the recovery pass re-associates integer-literal uses
with object-like macro definitions by source location (libclang macro-definition cursors).
Fidelity measured on `doomdef.h` at P6. `#if` platform selects: converter runs clang with
sidecar-fixed defines. `__FILE__`/`__LINE__`: already correct post-expansion.

## Enums ✓ (all probed)

```c
typedef enum { MT_PLAYER, MT_SHOTGUN = 5, NUMMOBJTYPES } mobjtype_t;
mobjinfo_t mobjinfo[NUMMOBJTYPES];
t = mobj->type;                /* enum var */
if (t < MT_SHOTGUN) ...        /* relational */
mobjinfo[t].speed;             /* index */
mobj->type = i;                /* int -> enum */
next = t + 1;                  /* enum arithmetic */
```
```das
enum mobjtype_t {              // always default (int) base
    MT_PLAYER
    MT_SHOTGUN = 5
    NUMMOBJTYPES
}
var mobjinfo : mobjinfo_t_s[int(mobjtype_t.NUMMOBJTYPES)]   // count const-folds as dim ✓
t = mobj.mtype                                // `type` renamed: das keyword
if (int(t) < int(mobjtype_t.MT_SHOTGUN)) {    // no relational ops on das enums ✓
}
mobjinfo[int(t)].speed
mobj.mtype = enum_from_int(type<mobjtype_t>, i)   // c_runtime; hides unsafe reinterpret ✓
next = enum_from_int(type<mobjtype_t>, int(t) + 1)
```
Duplicate enumerator values fine ✓ (aliases print first-declared name); out-of-range values
survive, compare by value, print `enum N` ✓.

## Structs & layout ✓ (all probed)

### Declaration, copy, layout
```c
typedef struct { thinker_t thinker; fixed_t x, y; } mobj_t;
mobj_t a, b;
a = b;                          /* member-wise copy */
```
```das
struct mobj_t {
    thinker : thinker_t
    x, y : int                  // fixed_t = int (16.16)
}
var a, b : mobj_t
a = b                           // deep POD copy incl. fixed-array members ✓
```
Layout law ✓: das == clang for every natural shape (pack, nested align, tail padding,
array stride, 8-byte fn-ptr fields). `sizeof`/`offsetof`/`_Alignof` always emit as das
`typeinfo sizeof` / `typeinfo offsetof<f>(type<T>)` / `typeinfo alignof` — self-consistent,
never clang constants.

### By-value param (das params are references ✓)
```c
void norm(vec_t v) { v.x /= v.len; use(v); }   /* caller's v untouched */
```
```das
def norm(v_in : vec_t) {
    var v = v_in               // local copy restores C by-value semantics
    v.x /= v.len
    use(v)
}
```
Emitted only when the body writes the param; read-only params pass through unchanged.
Struct return-by-value is direct ✓.

### Prefix punning / container_of ✓
```c
mobj_t *m = (mobj_t *)th;                     /* thinker is first member */
mobj_t *m2 = (mobj_t *)((byte *)p - offsetof(mobj_t, thinker));
```
```das
var m = reinterpret<mobj_t?>(th)
var m2 = reinterpret<mobj_t?>(intptr(p) - typeinfo offsetof<thinker>(type<mobj_t>))
```

### Packed structs — marshal-only (until the `[pack]` side-arc lands)
```c
#pragma pack(1)
typedef struct { short width; int ofs; } disk_t;   /* size 6 */
```
No das struct emitted; sidecar marks `disk_t` marshal-only → generated
`read_disk_t(bytes, ofs)` / `write_disk_t` using clang's packed offsets over a
naturally-aligned das struct; all access sites route through the readers.

## Bitfields ✓ (mechanism probed; `[c_bitfields]` macro is the P4 deliverable)

```c
struct BF { unsigned a : 3; int b : 5; short e; };
s.a = 9;                        /* truncates to 1 */
s.b;                            /* sign-extends */
s.a += 1;
```
```das
[c_bitfields(a = 3, b = 5)]     // macro synthesizes storage + property operators
struct BF {
    a : uint
    b : int
    e : int16
}
s.a = 9u                        // wraps to 1 ✓
s.b                             // shl/sar sign-extend ✓
s.a += 1u                       // compound routes through get+set ✓
```
What the macro generates (probed by hand ✓): backing `_bits0 : uint` per allocation unit at
clang's bit offsets; `def operator . a(s : BF) : uint` + `def operator . a := (var s : BF; v : uint)`
mask/shift pairs; unnamed `:N`/`:0` fields fold into the offsets clang reports. `[inline]`
rejected on property operators — interp pays a call per access; JIT/AOT inline. `__`-names
reserved → `_bits0`.

## Unions ✓ (mechanism probed; `[c_union]` macro is the P4 deliverable)

```c
typedef union { GCObject *gc; void *p; double n; long long i; } Value;
v.n = 3.5;
v.i;                            /* punning: memcpy semantics */
u.pt.x = 7;                     /* write through member's field */
```
```das
[c_union]                       // macro: fields -> one max-size/max-align _storage + operators
struct Value {
    gc : GCObject?
    p : void?
    n : double
    i : int64
}
v.n = 3.5lf
v.i                             // same bytes — punning defined by construction
u.pt.x = 7                      // ONE ref-returning operator per member covers this ✓
```
Generated per member (probed by hand ✓):
`def operator . n(var s : Value) : double& { unsafe { return *reinterpret<double?>(addr(s._storage)) } }`
— read, write, compound, nested-field, addr-of all through one operator; bitfield members
keep get/set pairs (bits aren't addressable). Anonymous unions flatten into the parent via
forwarding operators. (P: storage alignment source — max-align member type, or `[align_as]`
once the side-arc lands.)

## Arrays ✓ (all probed)

### Initialization — exact-size literals only
```c
int full[3] = {1, 2, 3};
int part[6] = {1, 2};           /* rest zeroed */
int sparse[NUM] = {[5] = 9};
char name[8] = "abc";
```
```das
var full : int[3] = fixed_array(1, 2, 3)           // ✓
var part : int[6] = fixed_array(1, 2, 0, 0, 0, 0)   // literal size MUST match ✓ — pad small ones
var sparse : int[NUM]                               // das zero-inits = C zeroing rule
// nonzero elements stored in module init:
sparse[5] = 9
var name : uint8[8] = cstr_array("abc", 8)          // (P: c_runtime compile-time macro — pads + NUL)
```

### Multi-dim + row pointers ✓
```c
int m[2][3] = {{1,2,3},{4,5,6}};
int (*row)[3] = &m[1];
(*row)[2];
```
```das
var m : int[2][3] = fixed_array(fixed_array(1, 2, 3), fixed_array(4, 5, 6))  // ✓
var row : int[3]? = addr(m[1])     // pointer-to-fixed-array is native ✓, row arith strides by 12 ✓
deref(row)[2]
```

### Decay
```c
void f(int a[]);
f(arr);
p = arr + 2;
```
```das
def f(a : int?)
f(addr(arr[0]))
p = addr(arr[0]) + 2
```

### Out-of-bounds = panic (safety oracle)
das range-checks `a[i]`; C OOB (UB) panics instead of corrupting. A stock-demo panic is a
real find; sidecar demotes that array to pointer-based access when vanilla behavior depends
on the overrun (over-indexed trailing arrays already route this way).

## Loops: if / while / do-while (Boris 2026-08-21)

`if`/`else` and `while` map 1:1 — nothing emitted beyond the direct form.

### do/while — the first-pass flag ✓ (probed)
```c
do {
    i++;
    if (i == 2) continue;      /* jumps to the condition test */
    work(i);
} while (cond(i));
```
```das
var _first = true
while (_first || cond(i)) {
    _first = false             // always the first body statement
    i++
    if (i == 2) {
        continue               // das continue re-tests the while header = C semantics ✓
    }
    work(i)
}
```
Probed exact: condition never evaluated on first entry (short-circuit), evaluated after
every pass including `continue` passes ✓. `break` 1:1. No goto anywhere.

Side-effecting condition (`do {…} while ((c = next()) != EOF)`) can't inline into the
header — fallback: `while (true) { body; c = next(); if (!(c != EOF)) { break } }`, with a
tail label for `continue` only if the body contains one.

### General for — the increment-first flag ✓ (probed)
Canonical counting loops take the O1 `for (i in range(n))` rewrite instead; everything
else lowers to:
```c
for (a; b; c) { ... continue ... break ... }
```
```das
a                              // init statements; C99 `for (int i…)` scope = wrap all in a bare block
var _f = false
while (true) {
    if (_f) {
        c                      // increment runs at loop top from pass 2 on
    }
    _f = true
    if (!(b)) {
        break
    }
    // body:
    //   continue -> loop top -> runs c, then tests b   = C semantics ✓
    //   break    -> exits, c not run                   = C semantics ✓
}
```
Probed exact (side-effect counter on `b`): eval order body→c→b matches C; `continue` runs
the increment, `break` skips it — both native, no labels. (Note: the naive
`while (b) { if (_f) c; … }` shape tests `b` before `c` — one increment stale; rejected.)

Alternative to profile (P1): body-block `finally` —
```das
a
while (b) {
    {
        // body
    } finally {
        c                      // probed: runs per iteration AND on continue ✓
    }
}
```
`finally` also runs on `break` (scope exit) — C's break skips `c` — so this form is valid
only when the body contains no `break`, or `c`'s effect is provably dead after the loop.
Profile both at P1; emit the faster one where A is eligible.

## switch — three-tier ladder (Boris 2026-08-21)

Tier 1 — **if/elif/else chain**, emitted whenever there is no fallthrough AND every
`break` sits in tail position of its case body (the majority of real switches). `break`
maps to nothing (end of branch); C `continue` inside a case maps directly to das
`continue` (no loop wrapper — no landmine):
```das
if (_cond == 1) {
    a()
} elif (_cond == 5) {
    b()
} else {
    d()
}
```

Tier 2 — **matched-flag loop**, the fully general semantic form (fallthrough, mid-body
break, default-anywhere). Below.

Tier 3 — **computed `goto var`** (optimization O6): dense hot switches become a bounds
guard + `goto base + _cond` jump table — a construct C itself doesn't have; the Lua VM
dispatch case (~85 cases per executed instruction) is the motivating beauty.

### Tier 2 in full ✓ (probed)

No labels, no goto: a single-iteration `while (true)` makes C `break` map verbatim;
`_cond` is evaluated once (C's rule); fallthrough is the monotonic `_flag`.

```c
switch (x) {
case 1:  a(); break;
case 5:  b();            /* falls through */
case 9:  c(); break;
default: d();
}
```
```das
while (true) {
    var _flag = false
    let _cond = x                    // controlling expr evaluated once
    _flag ||= _cond == 1
    if (_flag) {                     // case 1:
        a()
        break
    }
    _flag ||= _cond == 5
    if (_flag) {                     // case 5: (falls through)
        b()
    }
    _flag ||= _cond == 9
    if (_flag) {                     // case 9:
        c()
        break
    }
    _flag ||= !(_cond == 1 || _cond == 5 || _cond == 9)
    if (_flag) {                     // default: fires iff position reached or nothing matched
        d()
    }
    break
}
```
Rules:
- Shared labels (`case 0: case 1: body`) = several `_flag ||=` lines before one `if`.
- `default` anywhere: at its position, `_flag ||= !(match-any-case-in-switch)` — preserves
  both position-based fallthrough and match-none semantics ✓.
- Enum switches keep enum compares (`_cond == mobjtype_t.MT_X`) — no int casts, readable.
- **C `continue` inside a switch targets the enclosing loop** — emitting das `continue`
  inside the `while (true)` would loop the switch. Emission (only when the body contains
  `continue`): `_cont = true` + `break` inside; `if (_cont) { continue }` right after the
  switch-loop ✓.
- Nested switches: `_flag`/`_cond`/`_cont` numbered per switch (`_flag2`, …).
- Case bodies with declarations get their block scope from the `if` body.
- Duff's device (case labels inside a loop body): flag form can't enter mid-loop —
  state-machine fallback (P3 spec).
- Perf: dense hot switches (Lua VM dispatch: ~85 cases per instruction) pay a compare
  chain in interp — optimization tier O6 rewrites dense no-fallthrough switches to a
  computed-`goto` jump table when profiling demands; the flag loop stays the semantic
  default.

## Variadics & printf — generic + tuple + `apply` ✓ (Boris 2026-08-21, probed)

No language-level varargs in das and none planned. The design: variadic functions become
**generics over a trailing tuple** — fully type-safe, monomorphized per call shape
(C++-variadic-template style), no erasure, no runtime dispatch.

```c
double sum(int n, ...) { va_list v; va_start(v, n); … va_arg(v, T) … }
sum(4, 10, 2.5, 20, 0.5);
void I_Error(char *fmt, ...) { va_list v; vprintf(fmt, v); }
printf("x=%d y=%s\n", x, name);
```
The final design is a **hybrid** (Boris 2026-08-21): the tuple is the type-safe call ABI;
a generated `apply` prologue converts it once into a `CVaList` (variant array); the C
body then stays a *mechanical* transliteration — `va_arg` is a cursor pop, no thinking.

```das
variant CVal {
    i : int64
    d : double
    p : void?
}
typedef CVaList = array<CVal>

// c_runtime, once — the prologue converter (probed ✓ end-to-end):
def to_cvalist(va : auto) : CVaList {
    var lst : CVaList
    apply(va) $(name, field) {                       // walks tuple fields in order ✓
        static_if (typeinfo is_pointer(field)) {     // bool traits FOLD in static_if ✓
            unsafe {
                lst |> push(CVal(p = reinterpret<void?>(field)))
            }
        } static_elif (typeinfo is_float(field)) {   // va-promotion float→double
            lst |> push(CVal(d = double(field)))
        } static_elif (typeinfo is_double(field)) {
            lst |> push(CVal(d = field))
        } else {                                     // int-class incl. small ints, enums
            lst |> push(CVal(i = int64(field)))
        }
    }
    return <- lst
}

[variadic]                              // annotation: decl sugar + call macro + prologue
def sum(n : int; va : va_args) : double {
    // generated prologue: let va <- to_cvalist(_va_tuple)
    var _vac = 0                        // va_start(v, n)
    ...
    acc += double(va[_vac] as i)        // va_arg(v, int) — MECHANICAL cursor pop
    _vac++
    ...
}
sum(4, (10, 2.5, 20, 0.5))              // call site: trailing args = TUPLE literal ✓
def I_Error(fmt : uint8?; va : va_args) {
    c_vprintf(fmt, va)                  // forwarding = pass the CVaList
}
printf("x=%d y=%s\n", x, name)          // call macro wraps trailing args into the tuple
```
Probed ✓: tuple literals; `auto` instantiation per shape; `apply` walk with
`is_pointer`/`is_float`/`is_double` static dispatch (`n=5 sum=33 ptr_arm_ok`); call-macro
interception by name (`AstCallMacro` + `qmacro`). Trap found (corrected by Boris):
**`typename` reflects the binding's constness** — ordinary das rules: a non-`var` param's
tuple fields are `"float const"`, a `var` param's are `"float"` (both probed). String
compares DO fold in `static_if` but silently mis-match across constness; bool traits are
qualifier-immune — use those (hence the trait-macro sidequest).

Rules:
- The `[variadic]` annotation packages it: decl rewrite, per-function call macro tupling
  the trailing args, prologue emission. Fallback packaging: converter emits the call-macro
  class per variadic function (both halves probed).
- `va_arg(v, T)` = typed `as` pop at the cursor (mismatch panics = C UB oracle);
  `va_copy` = array + cursor copy; `va_start`/`va_end` dissolve.
- Structs through `...`: CVal gains a bytes arm if a suite demands (rare; ledgered).
- Empty varargs (`printf("hi")`) and 1-element tuples are macro special cases (P1).
- printf: the macro parses the constant format at das-compile time and type-checks against
  the tuple's static field types; **rendering binds CRT `snprintf` per directive** (split
  the format at `%`-conversions, one single-arg CRT call each, concatenate) — byte-exact
  by construction, killing the hand-written C99 conversion engine (bind-first strategy,
  stdlib-examples.md). Non-constant formats: `c_vprintf` = same splitter at runtime over
  the tuple walk.
- Cost: one instantiation per distinct call-site tuple shape (code size; acceptable).
- scanf family: same split; pointer out-args are ordinary `T?`.

## setjmp / longjmp — try/recover + panic ✓ (probed)

One das exception mode already implements panic via setjmp/longjmp — this lowering is
borderline identity. das `finally` is skipped on panic, which is exactly C's
no-cleanup-on-longjmp rule: semantics match by accident of design.

```c
jmp_buf buf;
if (setjmp(buf) == 0) { A; } else { B; }   /* Lua's luaD_rawrunprotected shape */
...deep below... longjmp(buf, 7);
```
```das
// c_runtime, once:
struct CJmpBuf {
    val : int
}
var _c_jmp_target : CJmpBuf?               // active longjmp target during unwind

def c_longjmp(var buf : CJmpBuf; v : int) {
    buf.val = v == 0 ? 1 : v               // C: longjmp value 0 coerces to 1
    unsafe {
        _c_jmp_target = addr(buf)
    }
    panic("longjmp")
}

// contained setjmp site:
try {
    A                                       // deep code longjmps out of here
} recover {
    unsafe {
        if (_c_jmp_target != addr(buf)) {
            panic("longjmp")                // not our buf (or a genuine das panic: target null) — rethrow ✓
        }
    }
    _c_jmp_target = null
    B                                       // buf.val carries the longjmp value ✓
}
```
Probed ✓: nearest-buf catch with value; multi-level targeted jump past an inner recover via
rethrow-from-recover; genuine panics pass through untouched (null target). General setjmp
(return value used arbitrarily / re-entry into the function tail) wraps the tail in the
trampoline: `while (_sj_run) { _sj_run = false; try { tail } recover { …check…; _sj_val =
buf.val; _sj_run = true } }` — C declares non-volatile locals indeterminate after longjmp,
so re-entry values are conforming. Lua P5: `LUAI_THROW/LUAI_TRY` → `c_longjmp`/the
contained pattern — `pcall` works fully.

Core-language side-arc (plan §13, same arc as `[pack()]`): native das setjmp/longjmp "as
is" — one das exception mode already implements panic via setjmp/longjmp, so exposing it
deletes this whole protocol. The try/recover lowering is the working fallback until then.

## Globals & initializers ✓ (probed)

```c
int leveltime;                          /* zero-init */
static int data[4];
static int *p = &data[1];               /* address-carrying initializer */
char *names[] = { "AB", "CD" };         /* pointer table into literals */
state_t states[] = { {S_NULL, A_Look, …} };   /* fn-ptr tables */
```
```das
var leveltime : int                     // das zero-inits ✓ = C
var data : int[4]
var p : int?                            // address-carrying init -> [init] fn (data is zero-init)
var _str_0 : uint8[3] = cstr_array("AB", 3)
var _str_1 : uint8[3] = cstr_array("CD", 3)
var names : uint8? [2]                  // NOTE the space: `?[` lexes as the safe-index operator ✓
                                        // filled in [init] (literals precede, so inline also legal)
var states : state_t[…] = fixed_array(state_t(sprite = …, action = @@A_Look), …)  // fn-ptr tables inline ✓

[init]
def _c2das_init_pointers {              // = C load-time static init; runs before main ✓
    unsafe {
        p = addr(data[1])
        names[0] = addr(_str_0[0])
        names[1] = addr(_str_1[0])
    }
}
```
Rules (probed ✓): das validates global-init dependency order — `addr(g)` inline is legal
only when `g` has an explicit initializer and precedes; zero-init pointees and circular
pointer globals must route through `[init]`. Policy: value inits at the declaration,
address-carrying inits inline where legal, `[init]` otherwise. Function-pointer tables
(`states[]`) initialize inline — no ordering constraint ✓.

## Pointers + `[c_function]` ✓ (all probed)

```c
void blit(byte *src, byte *dst, int n) {
    while (n--) *dst++ = *src++;
}
```
```das
[c_function]                    // whole body unsafe — probed macro, ~15 lines, precedent apply_in_context.das
def blit(src_in, dst_in : uint8?; n_in : int) {
    var src = src_in
    var dst = dst_in
    var n = n_in
    while (n != 0) {
        n = n - 1
        deref(dst) = deref(src)
        dst = dst + 1
        src = src + 1
    }
}
```
`[c_function]` emitted ONLY when the body contains unsafe ops — its count is the
port-progress metric for the follow-up story. Casts: `(T*)v` → `reinterpret<T?>(v)`;
`(intptr_t)p` → `intptr(p)` ✓; `p < q` → `intptr(p) < intptr(q)`; `NULL` → `null`;
negative indices `p[-2]` → `deref(p + (-2))` ✓; `void*`↔`T*` → explicit `reinterpret`.
Allocation model: all C objects live in raw memory (`c_malloc` ✓ / globals / stack) —
never `new`/`delete`, GC uninvolved, C manages lifetimes.
