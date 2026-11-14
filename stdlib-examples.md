# C-To-DAS — Standard Library Examples (normative)

The C standard library's das implementations — c_runtime designs with expected code, same
contract as [lowering-examples.md](lowering-examples.md): sections are added only after
their discussion round; **✓** = probe-verified, **(P: …)** = named probe/deliverable owed.
Standing rule (Boris): variadic libc entries are `[variadic]` macros; everything else is a
plain das function.

Corrections tagged **(F*n*)** were re-probed on daScript `6401904cf9` (2026-11-14); the tag is a
plain label. A ✓ that the re-probe did not bear out is corrected in place and tagged. Where the
translator emits a different shape on purpose, the text says what it emits and why.

## Memory: the GC ruling (Boris + discussion, 2026-08-21)

**The das GC heap is never used for any C data.** Reason — reachability: das GC is precise
(typed). It cannot see a pointer that has been incremented to an interior address
(`foo++`), stored into a raw byte buffer, round-tripped through `intptr`, or stashed in a
malloc'd C struct — all everyday C. Only a conservative (Boehm-style) scanner could, and
das has none. Any "GC will reclaim it" scheme for C pointers is therefore unsound by
construction; nothing C-side is ever traced.

## The bind-first strategy (Boris 2026-08-21)

**Bind the real C library wherever the boundary is raw pointers and scalars; reimplement
in das only what interleaves with converted-code semantics.** The c2das repo ships a small
native glue module (`dasCRuntime`, C++ shared module) whose job is `addExtern` lines, not
logic. Consequences:
- CRT behavior is native-exact by construction — the differential suites compare converted
  output against a binary using the *same* CRT.
- The das-side c_runtime shrinks to: the macros (`[variadic]`, `printf`, `[c_union]`,
  `[c_bitfields]`, `[c_function]`, `cstr_array`), alloca emission, setjmp protocol,
  `enum_from_int`, atexit list — the semantic layer only.
- What can never bind: anything taking a C va_list (our varargs are tuples) and anything
  calling back into converted code. That includes `qsort`/`bsearch` (F33): the CRT cannot call
  into das at all, shim or not, so no binding takes a converted comparator; both are c_runtime's
  own (below).
- The binding states what each function touches (F85): a CRT
  function that writes through a pointer argument is bound
  `SideEffects::modifyArgumentAndExternal` and a pointer reader `accessExternal`. With the
  writers bound `modifyExternal` and the readers `none`, `a = strlen(d); strcpy(d, s);
  b = strlen(d)` folded into one read on every tier, the interpreter included, and a caller's
  local passed to a helper whose pointer parameter is not `var` kept its old bytes under the JIT.

## malloc / free / calloc / realloc — bound CRT (Boris 2026-08-21)

Real C-level `malloc`/`free`/`calloc`/`realloc`, bound via dasCRuntime — **not** the das
heap, not das's `malloc` builtin (that is `das_aligned_alloc16`, das's own allocator).
C manages its own lifetimes exactly as the source already does.

```c
char *foo = malloc(123);
foo++;
...
foo--;
free(foo);                       /* fine: free receives the base address */
p = realloc(p, n2);
```
```das
var foo = reinterpret<uint8?>(malloc(123ul))   // dasCRuntime bind of CRT malloc
foo = foo + 1
...
foo = foo - 1
free(foo)                        // no tracing, no roots — nothing to reach
p = realloc(p, n2)               // native realloc: no size bookkeeping on our side
```
- `malloc(0)`, `free(NULL)`, alignment, growth behavior: CRT-exact by construction —
  nothing to match, it IS the native one.
- Freeing an interior/foreign pointer is UB in C and fails exactly like native (same CRT).
- Doom: the zone allocator (`Z_Malloc`) is converted C — one `malloc` at startup, managed
  internally.
- (P: dasCRuntime bind list lands with the repo skeleton — name-collision policy with das
  builtins: CRT binds live in the `crt` module namespace, converted code requires it
  qualified or the converter renames on conflict, e.g. das builtin `malloc` shadow.)

## mem* family — bound / already present ✓

`memcpy` exists as a das builtin (probed ✓); **`memset` does not** (F2,
re-probed `6401904cf9`): das has `memset8/16/32/64/128(ptr, value, count)`, the width in the
name and the count an `int` of elements. C's `memset` binds the CRT through dasCRuntime
(`crt::memset`, as plan §7 lists it), with `memmove`/`memcmp` and C's own `memcpy`, alongside
the malloc family; `memset8` is the das-side spelling where c_runtime fills bytes itself. All
operate on raw pointers — nothing to adapt. The builtin `memcpy` keeps one use: a marshal
accessor's one-field copy, `memcpy(dst, src, 1)` with an `int` size, which the JIT folds to a
single load where `crt::memcpy` is an opaque call (F81).

## stdio / FILE* — bound, close to verbatim (Boris 2026-08-21)

das `fio` already wraps the C `FILE*` API nearly 1:1 (`fopen`/`fread`/`fwrite`/`fseek`/
`ftell`/`fclose`/…); `FILE*` stays an opaque pointer on both sides. Where an entry is
missing (`ungetc`, `ferror`, `tmpfile`, `setvbuf`, …) it binds through dasCRuntime — same
CRT, same semantics. printf/scanf families are the variadic exception (lowering-examples.md);
`fputs`/`fgets`/`puts` bind directly. (P: exact fio-vs-bind split lands with the
dasCRuntime bind list; Doom mostly bypasses stdio via PureDOOM's file callbacks anyway.)

## string.h & the string bridge ✓ (Boris 2026-08-21, probed)

das strings are immutable; C strings are mutable `uint8?` memory. Three rules:

1. **Mutating functions bind CRT** via dasCRuntime (`strcpy`/`strcat`/`strncpy`/
   `sprintf`-into-buffer/…) — they operate on raw `uint8?` memory, das strings never
   involved. Read-only ones (`strlen`/`strcmp`/`strchr`/`strstr`) bind too (uniform);
   `strtod`/`strtol` bind (C locale is the dialect).
2. **`reinterpret<string>(p)` is the legal bridge C→das** (probed ✓: `print`, `length`,
   content-`==` against das literals all work on a NUL-terminated `uint8?`). It is an
   alias, not a copy — mutation flows through the view ✓ — so converted code emits it only
   at read-only bridge points (logging, das-API interop). Lifetime stays the buffer's.
3. **das literals are legal C read-only strings** (probed ✓: `reinterpret<uint8?>("hello")`
   is byte-walkable, NUL-terminated, pointer-stable — das literals are interned/static).
   Writing through it is UB — exactly C's write-to-string-literal UB. Symmetric by design.

Consequence for lowering (updates lowering-examples.md Strings):
```c
const char *msg = "hello";       /* immutable literal pointer */
char buf[8] = "abc";             /* mutable array copy */
```
```das
var msg : uint8? = unsafe(reinterpret<uint8?>("hello"))   // literal STAYS a literal — readable ✓
var buf : uint8[8] = cstr_array("abc", 8)                  // _str_N byte arrays only for mutable char[] inits
```

## math.h — das superset / bind ✓

das math covers the surface; anything exotic (`fmod` corner semantics, `frexp`/`ldexp`,
`nextafter`) binds the CRT function — which also guarantees **bit-exact** results against
the native baseline in the differential suites (same CRT, same libm). Doom is fixed-point
and barely touches libm; Lua leans on it heavily — bind-first makes Lua's number behavior
native-identical for free.

## qsort / bsearch ✓ (probed 2026-08-21)

C guarantees neither algorithm nor stability — any correct sort conforms (das `sort` is
qsort-family, unstable, same class). Probed bridges:
- das `sort` accepts a block adapter around the C comparator fn-ptr:
  `arr |> sort() <| $(a, b : int) { … return invoke(cmp, addr(la), addr(lb)) < 0 }` ✓
  (block params need local copies before `addr`).
- **Raw C memory is sortable as a dim view**: `deref(reinterpret<int[6]?>(raw)) |> sort()` ✓
  — but dim N is compile-time, and C `qsort`'s n is runtime.

Ruling — the general wrapper is c_runtime's own (the "collection of small wrappers"). As built
(F33), it is
C's own signature, not a generic over the element type:
```das
typedef CCompare = function<(var a : void?; var b : void?) : int>
def c_qsort(base : void?; n : uint64; size : uint64; cmp : CCompare)
    // the runtime's byte sort, `__builtin_sort_any_cblock` (the engine under daslib's `sort`),
    // the comparator in a block; runs under the interpreter and the JIT, AOT emits its C++ call;
    // cmp is the CONVERTED C comparator verbatim
def c_bsearch(var key : void?; base : void?; n : uint64; size : uint64; cmp : CCompare) : void?
```
Why not `base : auto(TT)?`: C's call carries `n` and `size` as run-time values and `base` as
`void *`, so the element type is not at the call site; the converter would have to recover it
from the comparator's casts, and a `base` reached through a `void *` variable carries none. The
comparator's pointer positions are `var`, as every data pointer parameter of converted code is
(lowering-examples.md, Pointers; F34), so a converted comparator arrives with no cast. The
das-`sort` dim-view path stays available for constant-N sites.

## atexit ✓ (Boris's form, probed 2026-08-21)

Global list + `[finalize]` walker (the das annotation for the shutdown flag —
`[shutdown]` is not an annotation spelling).

```das
var _c_atexit_list : array<function<() : void>>
var _c_atexit_ran = false

def c_atexit(f : function<() : void>) : int {
    _c_atexit_list |> push(f)
    return 0
}

def c_run_atexit {                   // once-guarded
    if (_c_atexit_ran) {
        return
    }
    _c_atexit_ran = true
    var i = length(_c_atexit_list) - 1
    while (i >= 0) {                 // LIFO ✓ = C rule
        invoke(_c_atexit_list[i])
        i--
    }
}

[finalize]
def _c_shutdown {
    c_run_atexit()                   // normal-return path ✓ probed (runs after main, LIFO)
}
```
`c_exit(code)` calls `c_run_atexit()`, flushes, then ends in das `exit_now(code)` — the atexit
run is required, since `exit()` skips normal context teardown (probed ✓: `[finalize]` does not
run) and `exit_now()` ends the process at once; the ran-flag makes the two paths safe together. Not das `exit`: re-probed on `6401904cf9` (F1), `exit(N)` keeps the code but prints `exit(N) called from …` and the
call stack on stdout, which a stdout-diffing harness would see. `[finalize(late)]` exists if ordering against other
finalizers ever matters.

## errno / time.h / rand — bind-first sweep (2026-08-21)

- **errno**: dasCRuntime exposes `c_errno() : int` / `c_set_errno(v)` over the real CRT
  errno — coherent by construction, since every bound CRT function sets the same one.
  Converter rewrites `errno` expressions into these calls; `EINVAL`-style constants ride
  the macro-constant recovery pass. Platform fact (F7):
  `strtol` overflow reads back `ERANGE` and base 1 `EINVAL`, but on glibc the libm calls through
  the module (`log1p(-2)`, `fmod(1, 0)`, `tgamma(-1)`, `remainder(1, 0)`) return NaN and leave
  errno at 0, so `EDOM` never arrives from libm there; MSVC's CRT differs. The differential
  suites compare against a native binary on the same libm, so they stay self-consistent.
- **time.h**: bind `time`/`clock`/`mktime`/`localtime`/`strftime` as demanded by suites.
  MSVC ABI mapping: `time_t` = int64, `clock_t` = int (32-bit long), `CLOCKS_PER_SEC` =
  1000. `struct tm` = nine ints — natural layout, matches the CRT's, so `localtime`'s
  static `tm*` reads directly. Doom gets time through PureDOOM's `gettime` callback (das
  harness clock), not time.h.
- **rand/srand**: bind CRT `rand`/`srand` — the MSVC LCG, so differential outputs match
  native bit-for-bit. Doom uses its own `M_Random` (converted C).
- **getenv**: bind (PureDOOM routes it through its callback anyway).
- **assert**: C `assert` → c_runtime print of `file:line: expr` + `c_abort()` (exit 3);
  `NDEBUG` is a sidecar define — both sides of the differential build with the same
  setting.
- signal.h, locale beyond "C": out of scope (dialect, already ledgered).

## alloca — das-stack fixed arena with a limit ✓ (Boris's final form, probed 2026-08-21)

Runtime-size alloca lowers to a **fixed-size per-function arena living on the das stack**
plus a bump offset — so longjmp unwinding frees it *by construction* (the frame vanishes),
no GC, no heap, no leak. Generated modules raise the das stack to fit
(`options stack = <sized per program, sidecar>`).

```c
void f(int n) {
    char *buf = alloca(n);           /* dies at function exit */
    for (...) { char *t = alloca(k); /* accumulates until FUNCTION exit (C rule) */ }
}
```
```das
options stack = 400000               // module header, sidecar-sized

[c_function]
def f(n : int) {
    var _c_astack : uint8[65536]     // per-function arena; limit sidecar-overridable per function
    var _c_aoff = 0
    // c_alloca site expansion (bump + guard, 16-aligned):
    assert(_c_aoff + n <= 65536)     // over-limit = panic (alloca overflow is UB in C anyway)
    var buf = addr(_c_astack[_c_aoff])
    _c_aoff += (n + 15) & ~15
    ...                              // loop allocas keep bumping — accumulate until function exit ✓ C rule
}
```
Probed ✓: `options stack = 400000` honored; recursion with 128KB arenas per frame works;
bump/guard mechanics correct; pointers trivially stable (one frame-resident buffer).

Rules:
- Constant-size alloca goes through the arena too (F24):
  a das local lives in its block, so a `uint8[N]` local hoisted at an alloca site inside a loop
  body dies with the iteration, while C's allocation lives to the function's exit and a pointer
  kept past the iteration dangles. The plain-local shape is correct only for a site at the
  function's top level, never inside a loop; the translator routes every alloca through the arena.
- Loop allocas accumulate in the arena until function exit (C rule); each site bumps, none
  reuse.
- longjmp past the frame: das stack unwinds, arena gone — **exact C semantics, zero
  bookkeeping** (this is why the heap-backed `inscope` variant was rejected: probed
  13.2MB leak across 200 panic unwinds).
- Over-limit alloca panics (guard) — C's stack overflow UB surfaced as a diagnostic;
  sidecar raises the per-function limit and `options stack` together when a program needs
  more.
- Escaping alloca pointers = UB in C, stays UB here (frame reuse) — same class as
  returning a stack address.
- gcc-torture's alloca tests (previously ledgered out) join the ratchet at P4.
