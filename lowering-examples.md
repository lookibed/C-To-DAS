# C-To-DAS — Lowering Examples (normative)

For every **discussed** C construct: the exact das code the converter is expected to emit.
This file is the emitter's golden reference — when converter output and this file disagree,
one of them is a bug to resolve deliberately. Families are added here only after their
discussion round; undiscussed families are absent, not implied.

Markers: **✓** = probe-verified on the in-tree binary (2026-08-21). **(P: …)** = expected
shape, named probe still owed. House rules for output: gen2, `options indenting = 4`,
formatter-run, lint relaxed (generated banner), das `struct` never `class`, C names
preserved (renamed only on keyword/static collision).

Corrections tagged **(F*n*)** were re-probed on daScript `6401904cf9` (2026-11-14); the tag is a
plain label. A ✓ that the re-probe did not bear out is corrected in place and tagged. Where the
translator emits a different shape on purpose, the text says what it emits and why.

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

One shim the shifts do need (F40): das defines `<<` and `>>` only for
a count of the shifted value's own type (`int << uint` and `int64 >> int` are error 30406), while
C promotes the count apart from the left side. The count takes the promoted left side's
spelling: `i64 << n` → `i64 << int64(n)`, `x >> u` → `x >> int(u)`, a literal its suffix.

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
x = cond ? f() : g();              /* calls in ternary arms */
if (p && p->refresh(p)) ...        /* short-circuit with effects: stays native — das && short-circuits */
for (i = 0, j = n; ...)            /* comma: statement sequence (see Loops) */
```
```das
c = getch()
if (c != EOF) {
}

let _t0 = *p                       // `*p` is the node `deref(p)` is (F102)
p++                                // a pointer step is das's `p++`, `p += n` (F102)
a[i] = _t0
i++                                // das ++ is statement-only ✓ (used throughout probes)

x = cond ? f() : g()               // das `?:` evaluates only the taken arm ✓ (F18) — stays inline
// an arm that carries hoisted statements (an assignment or a step inside it) takes the chain:
//   x = cond ? (n = f()) : g();
var _t1 : int
if (cond) {
    n = f()
    _t1 = n
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
| enum → another integer type | direct: `uint(e)`, `int64(e)`, `uint8(e)`, … give the bits `int(e)` gives; `float(e)` is error 30341 | ✓ F106 |
| fn-ptr across signatures (`actionf_t`) | `reinterpret` between function types; a union of function pointers is a `[c_union]` member like any other, no sidecar shim (F32: a function value is 8 bytes, the reinterpret is lossless, and a variant dispatching on the stored member calls with the wrong arity) | ✓ F32 |

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
- goto into ANOTHER CASE of a lowered switch (lstrlib.c's `goto dflt`, lvm.c's `goto ret`):
  each case group is its own branch, so the label sits in no scope the goto sees ("can't find
  label"). The goto re-dispatches the switch instead: the label is a case of its own number in
  the switch's goto variable `_gotoN`, the goto stores the number and jumps to a
  `label K:  // re-dispatch` at the top of the loop body, and the label's branch resets it to 0
  (F60).

## Functions — declaration shapes

```c
static void helper(void) {}        /* internal linkage */
inline int sq(int x) { ... }
int cmp(const void *a, const void *b);
int knr(a, b) int a; char b; { ... }     /* K&R definition */
int main(int argc, char **argv) { ... }
```
```das
def private helper {}              // statics = private; renamed `<tu>_helper` only on cross-TU collision
def sq(x : int) : int {}           // `inline` dropped — das inlines on its own
def cmp(var a : void?; var b : void?) : int {}   // every data pointer parameter is `var`, `const` or not (F3)
def knr(a : int; b_in : int) : int {   // K&R: clang types the function by its PROMOTED parameters and a call
    let b = uint8(b_in)            // passes them, so the parameter is declared promoted and converted on entry (F55)
}
[export]
def main : int {                   // synthesized wrapper
    c_runtime_init("prog")         // argv build; argv[0] = the C file's stem (F56)
    return c_main(c_argc(), c_argv())   // `return N` from main sets the process exit code ✓ (F56)
}
```
The wrapper (F56): `argv[0]` has no
das source that is the same on every tier (the interpreter and the JIT see the daslang binary and
the script path, a `-exe` binary its own path, the AOT host nothing), so it is the C source
file's stem, the name a native build carries; the program's own arguments are `get_user_args`
(what follows `--`). No stdio setup is needed: the CRT's streams are the process's. C's
`exit(code)` is `c_exit(code)`: atexit list, flush, then das `exit_now(code)`, not das `exit`,
which keeps the code but prints `exit(N) called from …` and the call stack on stdout (F1).
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
if (s[0] == 'A') {                                        // a `uint8` compares by `==`/`!=` with a literal in its range (F106)
}
```
One literal is not a legal C string (F10): the empty das literal `""`
is a **null pointer** at runtime, so `reinterpret<uint8?>("")` is `null` where C's `""` points at
one NUL byte. The emitter gives the empty literal storage (`cstr_array("", 1)`). An embedded NUL
is safe: `length("a\0b")` is 1, but the bytes after the NUL stay in the literal's storage on every
tier, as C's do (F94).
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

Dialect note (F22): the `int` reading above is the `msvc`
dialect's. Under the `linux` host dialect, which the differential suites run under, clang gives
an enum without a negative enumerator the underlying type `unsigned int`: the relational compare
is `uint(t) < uint(mobjtype_t.MT_SHOTGUN)`, and an enumerator may hold a value past `INT_MAX`
(`enum flags { F_TOP = 0x80000000u }`).

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
never clang constants, with two exceptions the binary forces:
- `offsetof` of a `[c_union]` member: the member is an operator over the storage, not a field,
  so `typeinfo offsetof<i>(type<Mix>)` names nothing; every union member sits at 0 and the
  emitter spells the constant (F31).
- `_Alignof` where das aligns below clang (a record of bitfield units under the Itanium ABI,
  F5), of a marshal-only record, and of a `va_list`: clang's value as a literal, `T(4)`;
  everywhere else `T(typeinfo alignof(type<S>))` (F54).

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
Emitted for **every** record parameter, written or not (F50):
a record parameter the body never writes is still the caller's object, and a write the callee
makes through another pointer during the call shows through it (`f(a, &a)` storing through the
pointer, then reading the parameter, returned 5 where C returns 1). A scalar or pointer
parameter the body writes needs no copy: das passes it by value, so it is declared `var` and
written in place. Struct return-by-value is direct ✓.

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
naturally-aligned das struct; all access sites route through the readers. A one-field accessor
copies through the das builtin `memcpy` with an `int` size, which the JIT folds to one load;
`crt::memcpy` is an opaque call per byte there (F81).

Not every packed record is marshal-only (F51):
one whose plain fields each sit at a multiple of their das alignment converts as an ordinary
struct, through byte units and padding fields (`packed { unsigned a : 3; char c; unsigned b : 20; }`
→ `[c_bitfields(_bits0 = "uint8", a = 3, _bits1 = "uint8[3]", b = 20)]`, size 5). A plain field
off its das alignment (`packed { char c; int n; }`, as `disk_t` above) stays marshal-only.

## Bitfields ✓ (mechanism probed; `[c_bitfields]` macro is the P4 deliverable)

```c
struct BF { unsigned a : 3; int b : 5; short e; };
s.a = 9;                        /* truncates to 1 */
s.b;                            /* sign-extends */
s.a += 1;
s.a++;
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
s.a += 1u                       // C's `s.a++`: das has no `++`/`--` on a property (F26)
```
What the macro generates (probed by hand ✓): backing `_bits0 : uint` per allocation unit at
clang's bit offsets; `def operator . a(s : BF) : uint` + `def operator . a := (var s : BF; v : uint)`
mask/shift pairs; unnamed `:N`/`:0` fields fold into the offsets clang reports. `[inline]`
rejected on property operators — interp pays a call per access; JIT/AOT inline. `__`-names
reserved → `_bits0`.

Re-probed corrections:
- **Unit width and layout** (F5): `_bits0 : uint` per allocation unit
  mirrors clang under the MSVC ABI these documents assume (`e` at 4, size 8). Under the Itanium
  ABI (Linux) clang packs the unit to the bytes used, yet the declared `unsigned` still aligns the
  struct: `e` at byte 2, size 4, align 4. The das mirror `{ _bits0 : uint8; e : int16 }` has size 4
  but align 2, and no das spelling gives size 4 / align 4 / `e` at 2. The unit width therefore
  comes from the C-IR bit offsets, not always `uint`.
- **The annotation's grammar** (F25): widths alone cannot
  say where clang's units start, how wide they are or where padding sits (`unsigned : 2` leaves a
  gap, `int : 0` moves the next field to a new unit), so the macro reads its arguments in order:
  `_bits<N> = "uint8"` opens a unit (a string: `uint8` is a keyword the annotation grammar does
  not take as a value), `_<K> = n` skips `n` bits, `name = width` places a field. With no unit
  open a field opens one sized by its own type, so `[c_bitfields(a = 3, b = 5)]` above is the
  default form, exact under the `msvc` dialect.
- **`++`/`--`** (F26): rejected on a property ("can't be applied to
  non reference"); a step is spelled as the compound store.

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
— read, write, compound, `++`/`--`, nested-field, addr-of all through one operator; bitfield
members keep get/set pairs (bits aren't addressable).

Re-probed corrections:
- **A second operator per member** (F28): the `var` operator does not
  match a const base, so a union read through a `let` parameter fails with
  `field 'i' not found in U const`. The annotation adds an operator over a const union that
  returns the value; das picks the ref one for a `var` base and the value one for a const base,
  with no ambiguity.
- **Storage size and alignment** (F27, was the open P): `_storage` is `U[k]`, `U` the unsigned type of the
  alignment. A structure annotation's `apply` runs at parse time, before inference: a struct
  declared earlier is resolved and sized there, a later one is an alias, a dimension spelled by a
  constant is unfolded. Where the members cannot give the numbers (those cases, or clang's
  alignment above the members' das alignment) the converter states them:
  `[c_union(size = 4, align = 4)]`. Past align 8 no unsigned type aligns. The bare `[c_union]`
  above is the default form, exact for `Value`.
- **Initializers**: a struct literal cannot name a member (members are operators), so a union's
  initializer is the declaration and a store: `var u : U` then `u.d = 2.5lf`.
- **Anonymous unions** (F29): the translator does not flatten.
  The member is an explicit field `_anon<N>` (its index) of the anonymous record type, and `s.i`
  is spelled `s._anon1.i`, the path clang's own `MemberExpr` chain takes. Forwarding operators
  on the parent stay a readability rewrite for the optimization tier.
- **Unions of function pointers** (F32): members of a `[c_union]` like any other, one 8-byte
  storage, every member a reinterpret of the same bits; no sidecar entry and no variant.

## Arrays ✓ (all probed)

### Initialization — exact-size literals only
```c
int full[3] = {1, 2, 3};
int part[6] = {1, 2};           /* rest zeroed */
int sparse[NUM] = {[5] = 9};
char name[8] = "abc";
int *ptrs[2] = {0, 0};
```
```das
var full : int[3] = fixed_array(1, 2, 3)           // ✓
var part : int[6] = fixed_array(1, 2, 0, 0, 0, 0)   // literal size MUST match ✓ — pad small ones
var sparse : int[NUM]                               // das zero-inits = C zeroing rule
// nonzero elements stored in module init:
sparse[5] = 9
var name : uint8[8] = cstr_array("abc", 8)          // (P: c_runtime compile-time macro — pads + NUL)
var ptrs : int? [2] = fixed_array<int?>(null, null) // an array of data pointers names its element type (F41)
```
`fixed_array(null, null)` infers `void?[2]`, which a `var g : int? [2]` refuses ("int?[2] -const =
void?[2]"); a row of nulls inside a nested literal does the same (F41).

### Multi-dim + row pointers ✓
```c
int m[2][3] = {{1,2,3},{4,5,6}};
int (*row)[3] = &m[1];
(*row)[2];
```
```das
var m : int[2][3] = fixed_array(fixed_array(1, 2, 3), fixed_array(4, 5, 6))  // ✓
var row : int[3]? = addr(m[1])     // pointer-to-fixed-array is native ✓, row arith strides by 12 ✓
(*row)[2]
```

### Decay
```c
void f(int a[]);
f(arr);
p = arr + 2;
```
```das
def f(var a : int?)             // data pointer parameters are `var` (F3)
f(addr(arr[0]))
p = addr(arr[0]) + 2
```
An index is `int`, `int64`, `uint` or `uint64` only (error 30184): a `char` or `short` subscript
widens to `int`, under the array index and the pointer step alike (F43).

### Out-of-bounds = panic (safety oracle)
das range-checks `a[i]`; C OOB (UB) panics instead of corrupting. A stock-demo panic is a
real find; sidecar demotes that array to pointer-based access when vanilla behavior depends
on the overrun (over-indexed trailing arrays already route this way).

One C-defined address the range check refuses (F45): `&a[N]`, one past the end. `addr(a[N])` panics ("index out
of range, 3 of 3"). A constant `N` is spelled `addr(a[0]) + N`; a `k` that can reach the length
is `addr(a[0]) + end_index(k, N)` (c_runtime `c_bounds`: an unsigned compare against `N` that
panics in das's wording, so the check stays everywhere but one past the end).

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

### General for — four shapes, the first that applies ✓ (probed)
Ruling 2026-11-01 (13), F66: the range form is the default and a body without `continue` takes its
increment last; `--loops while` (the sidecar's `"loops": "while"`) is the option that turns the
range form off. The converter's rule: a `for`
is the first of these that applies.

1. **The range loop** (O1): `for (T i = a; i < n; ++i)` (or `i++`, `i += 1`) with `T` a 32- or
   64-bit integer the initializer declares, the test comparing `i` with a bound of `i`'s own type,
   the body never writing `i` or taking its address, and the bound invariant (literals, enumerators,
   `sizeof`, and the function's own locals and parameters that the body never writes and nothing in
   the function takes the address of, under casts, `+`, `-`, `*`; never `i` itself, a call, a
   global, a load through a pointer or a volatile object) is
   `for (i in range(a, n))` — `range`, `range64`, `urange` or `urange64` by `T`, `range(n)` when
   `a` is the literal 0. das evaluates `a` then `n` once (C's order; with the bound invariant, C's
   every-pass test); `i` dies with the loop as C99's does; `continue` reaches the next value as C's
   increment does; a start past the bound runs no pass. The start's
   hoisted statements, when it has any, go in a block of their own before the loop.
2. **The trailing increment**: a body holding no `continue` of this loop (one outside every nested
   loop; a `continue` inside a `switch` belongs to this loop and counts) is
```das
a
while (b) {
    // body
    c
}
```
   A `break`, `return` or `goto` out of the body skips `c`, as C does, and a body ending in one
   takes no increment, which no pass would reach.
3. **The `finally` block**: a body with a `continue` that never leaves the loop (no `break` at its
   level, no `return`, no `goto`) is
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
   `finally` also runs on `break` (scope exit) while C's `break` skips `c`, which is why a body with
   a `break` at its level takes shape 4 instead.
4. **The increment-first flag** otherwise:
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

The split is measured: the interpreter runs
the range loop fastest, then the trailing increment, the `finally` form and the flag; the JIT
compiles all four to the same code.

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

How the translator prints tiers 1 and 2 (F105): as c_runtime's call macro, C's own shape —
```das
c_switch (x) {
    case (1) {
        a()
        break
    }
    case (5) {
        b()                          // no leaving statement: falls into the next arm
    }
    case (9) {
        c()
        break
    }
    case (_) {                       // default; `default {` is a syntax error, `_` stands for it
        d()
    }
}
```
The macro expands before inference to the if-chain or the matched-flag loop below under the same
choice, and the expansion's nodes are the spelled tiers' nodes in the same order, so the two
tiers stay the semantic reference. A switch a goto re-dispatches, one under a jump table and
Duff's device keep the spelled lowering.

### Tier 2 in full ✓ (probed)

No labels, no goto (unless a C `goto` enters another case: see goto / labels, F60): a
single-iteration `while (true)` makes C `break` map verbatim;
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
- Case bodies with declarations get their block scope from the `if` body, except a declaration
  at the switch body's own level that a later group names: C scopes it to the rest of the body
  (`case 0:; int v = 1; … case 1: v = 7;`), so it is declared before the lowered switch as a bare
  `var v : T`, its initializer the assignment where C declares it (F53).
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
        static_if (typeinfo is_pointer(field) || typeinfo is_function(field)) {   // bool traits FOLD in static_if ✓
                                                     // a function value is no `is_pointer` (F38)
            unsafe {
                lst |> push(CVal(p = reinterpret<void?>(field)))
            }
        } static_elif (typeinfo is_float(field)) {   // va-promotion float→double
            lst |> push(CVal(d = double(field)))
        } static_elif (typeinfo is_double(field)) {
            lst |> push(CVal(d = field))
        } static_elif (typeinfo stripped_typename(field) == "bool") {   // no `int64(bool)` in das (F4);
            lst |> push(CVal(i = field ? 1l : 0l))   // stripped_typename drops the qualifiers
        } else {                                     // int-class incl. small ints, enums
            lst |> push(CVal(i = int64(field)))
        }
    }
    return <- lst
}

[variadic]                              // annotation: decl sugar + call macro + prologue
def sum(n : int; va : va_args) : double {
    // generated prologue: let va <- to_cvalist(_va_tuple)
    var v = va_begin(va)                // va_start(v, n): a CVaCursor over the list (F35)
    ...
    acc += double(va_i(v))              // va_arg(v, int) — MECHANICAL cursor pop
    ...
}
sum`va(4, (10, 2.5, 20, 0.5))           // call site in the same module: the macro's own expansion (F37)
[variadic]
def I_Error(var fmt : uint8?; va : va_args) {
    var v = va_begin(va)
    c_vprintf(fmt, va_rest(v))          // forwarding = the list from the cursor on (F36)
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
- `va_arg(v, T)` = typed pop at the cursor, `va_i(v)` / `va_d(v)` / `va_p(v)` (mismatch panics =
  C UB oracle).
- A `va_list` is a C object that travels (F35): a function takes one as a parameter and its pops advance
  the caller's list, and `va_copy` copies one into another variable. A bare `int` cursor cannot
  cross a call. It is c_runtime's `struct CVaCursor { list : CVaList const?; at : int }`:
  `va_start` = `v = va_begin(va)` (not dissolved), `va_copy` = plain assignment (the list is
  never written, so nothing else is copied), a `var` parameter of the struct is the caller's own
  cursor, `va_end` dissolves.
- Forwarding (F36): C forwards a `va_list`, never the function's own arguments, and the list may
  stand past its start or belong to a function that is not variadic itself
  (`vlog(const char *fmt, va_list ap)`). `vprintf(fmt, ap)` is `c_vprintf(fmt, va_rest(ap))`.
- Call sites (F37): the annotation registers the call macro
  after the parser has read the definition, and the parser binds a call to a call macro as it
  reads the call, so a C-spelled call above the definition or inside it finds no function. A
  call of a variadic function of the same module is therefore spelled as the macro's expansion,
  ``f`va(fixed…, (t1, t2))`` (`(a,)` for one trailing argument, `VaNone()` for none); the
  library's variadics (`printf`) keep C's spelling.
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

"Used arbitrarily" is narrower than it reads (F58):
the trampoline reruns the site's whole statement on re-entry, so an operand read before the call
is read again (`r = g + setjmp(buf)` with `g` changed before the longjmp gives the new `g`, C the
old). The general form takes the shapes ISO C 7.13.1.1p4-5 allows (the whole expression of an
expression statement, `!setjmp(…)`, a compare with an integer constant, the whole controlling
expression of a selection or iteration statement) plus the common extension, a store of the
whole value (`r = setjmp(buf)`, a declaration's initializer, `return setjmp(buf)`); any other
read of the value fails closed.

Tier note, re-probed on `6401904cf9` : a `return`,
`break` or `continue` inside a `try` or `recover` arm leaves the function or the loop under the
interpreter and the JIT alike. Earlier builds did not (the JIT left only the arm, then `return`
in an arm was error 30299; F75, F96, F97), which is why the translator still wraps an arm that returns
in an invoked block.

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
(`states[]`) initialize inline ✓, with one ordering constraint (F79): a
global's initializer depends on every global and function it names and, transitively, on
everything their bodies reach (`@@f` pulls in every global `f`'s body names, through calls too);
a path leading back to the global is error 31104 "global variable initialization loop".
PureDOOM's menu tables (MainMenu → M_NewGame → EpiDef → … → MainMenu) are such a cycle. An
initializer that reaches its own global is assigned in `[init]`; an acyclic one stays inline.

Two more facts of the binary:
- An address under `+` in a global initializer takes its own `unsafe` (F48): `var e : int? = unsafe(addr(a[0]) + 3)` is error 31000;
  `unsafe(unsafe(addr(a[0])) + 3)` compiles.
- Every generated module carries `options solid_context` (F80):
  it builds and runs under the interpreter, the JIT, the exe and the
  AOT host, and gives a global a fixed address in the JIT's code instead of a lookup per access.

## Pointers + `[c_function]` ✓ (all probed)

```c
void blit(byte *src, byte *dst, int n) {
    while (n--) *dst++ = *src++;
}
```
```das
[c_function]                    // whole body unsafe — probed macro, ~15 lines, precedent apply_in_context.das
def blit(var src : uint8?; var dst : uint8?; var n : int) {
    while (n != 0) {
        n = n - 1
        *dst = *src
        dst++
        src++
    }
}
```
Corrected (F3): the earlier shape
`def blit(src_in, dst_in : uint8?; n_in : int)` with `var dst = dst_in` does not compile. A
non-`var` parameter `dst_in : uint8?` is `uint8? const`, a local copy of it is `uint8 const?`
(const pointee), and `deref(dst) = …` is "can't write to a constant value"; a `let` pointer also
does not return as `T?` (error 30343) or copy its pointee pointer out (F46). So every data pointer parameter is `var`, whatever C's `const`,
and a written scalar or pointer parameter is written in place: das passes it by value. The
const is never reinterpreted away (upstream: the declared type is the contract the optimizer
reads). A function-pointer type takes `var` at the same positions, since a parameter's
constness is part of a das function type (F34).

`*p` and `deref(p)` compile to the same node; `p++`, `p--`, `p += n`, `p -= n` step a pointer on
every lvalue kind (F102). das reads `*q++` as `(*q)++`, not
C's `*(q++)`, so the step stays its own statement.

`[c_function]` emitted ONLY when the body contains unsafe ops — its count is the
port-progress metric for the follow-up story. Casts: `(T*)v` → `reinterpret<T?>(v)`;
`(intptr_t)p` → `intptr(p)` ✓; `p < q` → `intptr(p) < intptr(q)`; `NULL` → `null`;
pointer subscripts stay subscripts, negative ones included: `p[-2]` → `p[-2]` ✓ (F100: one node, the element `deref(p + (-2))` reaches); `p == q` between
two data pointers → `intptr(p) == intptr(q)` (F44: `==` across constness is error 30262); a
computed pointer less a count → `ptr + -(n)` (F59: `-` takes a pointer variable only);
`void*`↔`T*` → explicit `reinterpret`.
Allocation model: all C objects live in raw memory (`c_malloc` ✓ / globals / stack) —
never `new`/`delete`, GC uninvolved, C manages lifetimes.
