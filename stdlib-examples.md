# C-To-DAS — Standard Library Examples (normative)

The C standard library's das implementations — c_runtime designs with expected code, same
contract as [lowering-examples.md](lowering-examples.md): sections are added only after
their discussion round; **✓** = probe-verified, **(P: …)** = named probe/deliverable owed.
Standing rule (Boris): variadic libc entries are `[variadic]` macros; everything else is a
plain das function.

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
  calling back into converted code (qsort's comparator CAN bind if the fn-ptr shim wraps —
  P: qsort callback bridging when we reach it).

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

`memcpy`/`memset` exist as das builtins (probed ✓); `memmove`/`memcmp` bind via
dasCRuntime alongside the malloc family. All operate on raw pointers — nothing to adapt.

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

Ruling — the general wrapper is c_runtime's own typed generic (the "collection of small
wrappers"):
```das
def c_qsort(base : auto(TT)?; n : int; cmp : function<(a, b : void?) : int>)
    // ~25-line quicksort over pointer arith; TT supplies element size + typed swap via deref;
    // cmp is the CONVERTED C comparator verbatim (C declares it over const void* — so do we);
    // call sites: invoke(cmp, reinterpret<void?>(pa), reinterpret<void?>(pb))
def c_bsearch(key : void?; base : auto(TT)?; n : int; cmp : function<(a, b : void?) : int>) : TT?
```
Monomorphizes per element type (the converter knows T at every qsort call site — `TT` comes
from `base`); comparators need zero adaptation. The das-`sort` dim-view path stays
available for constant-N sites.

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
`c_exit(code)` calls `c_run_atexit()` before das `exit` — required, since `exit()` skips
normal context teardown (probed: the unbalanced-env atexit warning); the ran-flag makes
the two paths safe together. `[finalize(late)]` exists if ordering against other
finalizers ever matters.

## errno / time.h / rand — bind-first sweep (2026-08-21)

- **errno**: dasCRuntime exposes `c_errno() : int` / `c_set_errno(v)` over the real CRT
  errno — coherent by construction, since every bound CRT function sets the same one.
  Converter rewrites `errno` expressions into these calls; `EINVAL`-style constants ride
  the macro-constant recovery pass.
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
- Constant-size alloca skips the arena: plain `uint8[N]` local.
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
