# C-IR — the interchange AST format (spec v0.1)

The contract between frontends ("dumpers") and the das backend (plan §4.0). A dumper
converts one C translation unit into one C-IR file; the backend consumes C-IR only and
never sees clang, CBOR, or C source. Two dumpers exist by design (das: ast-dump=json +
dasClangBind layout; Rust: the C2Rust-fork serializer); their outputs for the same TU must
be **byte-identical** — that is the differential-frontend test.

Guiding rules:
1. **C-shaped, semantics-faithful, not pre-lowered.** C-IR carries C's own constructs
   (do-while, switch with fallthrough, goto, bitfields, designated inits in resolved
   positional form). All lowering (flag loops, matched-flag switch, property operators…)
   is the backend's job, spec'd in lowering-examples.md. The IR never encodes a lowering
   decision.
2. **Answers, not homework.** Everything Clang computed is baked in: every implicit
   conversion is an explicit cast node with a `castKind`; layout (offsets, sizes,
   alignment, bit offsets) is in the type table; constants are evaluated. A backend must
   never re-derive C semantics.
3. **Fail closed.** A dumper meeting anything it cannot represent exactly (unknown
   castKind, unsupported construct) errors out with location — never emits a guess.
4. **Deterministic bytes.** Canonical serialization (§8) so equal input ⇒ equal bytes.

Additions and corrections tagged **(F*n*)** (plain labels) are what a working dumper had to add
or normalize to carry real programs, checked against daScript `6401904cf9` (2026-11-14). All are
additive members, absent when empty, so `"cir"` stays `0.1`; a second dumper must write the same
bytes for the byte-diff to hold.
## 1. Container

One JSON file per TU: `<name>.cir.json`, UTF-8, LF. A program is a manifest
`program.cir.json` listing TU files plus link-level facts (§7).

Top level of a TU file, exactly these keys in this order:

```json
{
  "cir": "0.1",
  "producer": "c2das-dumper-a 0.1 / clang 22.1.5",
  "target": { "triple": "x86_64-pc-windows-msvc",
              "int": 32, "long": 32, "llong": 64, "ptr": 64, "char_signed": false },
  "tu": "p_mobj.c",
  "types": [ ... ],
  "decls": [ ... ]
}
```

`target` states the dialect the dump was made under (LLP64 default). The backend refuses
mismatched targets across a program. `char_signed` is `false` in both of the translator's targets
(F17): `char` as a signed 8-bit type and a C string as unsigned bytes (`uint8?`, what every
`crt` bind takes) cannot coexist in the lowering, so the dumper passes `-funsigned-char` and
`char` dumps as `w:8, signed:false`.

## 2. References

- Types are interned in `types[]`; everything references them by index (`"t": 14`).
  Interning order: first use, depth-first over `decls[]` — deterministic.
- Declarations reference each other by symbol name (C's own linkage model), not index;
  file-scope statics are emitted with their TU-qualified name already applied
  (`"name": "p_mobj__count"`, `"c_name": "count"`).
- Expression/statement nodes are inline trees (no ids).

## 3. Types (`types[]` entries)

Every entry: `{ "k": <kind>, ...fields }`. Kinds and their fields:

| k | fields | notes |
|---|---|---|
| `void` | — | |
| `int` | `w` (8/16/32/64), `signed` (bool), `spell` ("unsigned long", "char", …) | ALL integer types incl. `_Bool` (`w:8, spell:"_Bool"`) and enums-as-values never appear here — enums are their own kind |
| `float` | `w` (32/64), `spell` | `long double` dumps as w:64 (dialect) |
| `ptr` | `to` (type ref) | |
| `array` | `elem`, `count` (int; -1 = incomplete/flexible) | |
| `func` | `ret`, `params` [type refs], `variadic` (bool) | |
| `struct` / `union` | `name` (or "" anon), `size`, `align`, `packed` (bool), `fields` | field: `{ "name", "t", "off" (byte offset), "bit_off", "bit_w" }` — `bit_off`/`bit_w` present only for bitfields (bit_off is from byte 0 of the record); unnamed bitfield padding appears as `"name": ""`. A field named `""` **without** `bit_w` is an anonymous member (a struct or union member with no declarator): its `t` is the anonymous record, its `off` clang's; clang's `MemberExpr` chain reaches the inner members through it, so a `member` node naming it is that field of the node's record type (F30). A field whose array dimension is spelled by one enum constant carries `dims` (§4, F21) |
| `enum` | `name`, `spell`, `items`: `[{ "name", "v" (int64) }]` | values ALWAYS evaluated; underlying is int32 (the `msvc` dialect). Under the `linux` dialect clang gives an enum without a negative enumerator the underlying type `unsigned int`: such an enum carries `"signed": false` after `items` (absent for a signed one, so the `msvc` bytes are unchanged), and an enumerator may hold a value past INT_MAX (F22) |
| `typedef` | `name`, `to` | kept for readable backend output; semantically transparent |

Library types the IR carries opaque (F39): glibc's `jmp_buf` (`struct __jmp_buf_tag[1]`) and a
`va_list` (linux `struct __va_list_tag[1]`, msvc a `char *`) are not records the program defines;
their fields are libc's or the ABI's, which the lowering replaces by its own protocol, and
msvc's `va_list` desugars to a plain pointer the IR could not tell from a `char *`. A dumper
writes each as one opaque `struct` named by the C type: `jmp_buf` with one `int` field `val`
(size 4, align 4); `va_list` with one field `words`, `unsigned long long[3]` (24, 8) under
`linux` and `unsigned long long[1]` (8, 8) under `msvc`, `packed: false`, its `spell` `va_list`
(a C record tagged `va_list` spells `struct va_list`, which tells the two apart). A `va_list`
parameter is that record under `msvc` and a pointer to it under `linux` (the decayed array), as
clang types it.

## 4. Declarations (`decls[]` entries)

| k | fields |
|---|---|
| `global` | `name`, `c_name`, `t`, `static` (bool), `extern` (bool — declaration only, no storage), `init` (expr or null), `loc` |
| `func` | `name`, `c_name`, `t` (func type ref), `static`, `params` [{`name`,`t`}], `body` (compound stmt or null for prototypes), `loc` |
| `record` / `enumdef` / `typedefdecl` | `t` (ref into types[]) — ordering anchors for readable emission, `loc` |

Local statics are hoisted here by the dumper as `global` with `"from_func": "f"`; two static
locals of one name in one function are `<fn>_<name>` and `<fn>_<name>1` (F47).

`dims` (F21): a `global`, a `decl` statement and a record field carry `dims` when an array
dimension of the declarator is spelled by one enum constant whose value is the count: one
`{ "enum_t", "item" }` per dimension, outermost first, `item` empty for a dimension not so
spelled, the member absent when none is. `array.count` is the folded integer and the type table
interns `T[6]` once however the source wrote it, so without `dims` no backend can emit
`mobjinfo : mobjinfo_t[int(mobjtype_t.NUMMOBJTYPES)]` (lowering-examples.md, Enums). A
dimension that is an expression over constants (`N + 1`) keeps the bare count.

`loc` (F16) is the resolved location. clang's `-ast-dump=json` omits `file` and `line` from a
location that repeats the previous node's, in tree order; a dumper reading that dump carries
the last seen file and line forward, and every dumper writes the resolved values.

## 5. Statements

`{ "s": <kind>, ...fields, "loc": … }`. Kinds:

`compound` (`body`: [stmt]) · `decl` (`name`,`t`,`init` expr|null — one per variable;
dumpers split multi-declarators) · `expr` (`e`) · `if` (`cond`,`then`,`else`|null) ·
`while` (`cond`,`body`) · `do` (`body`,`cond`) · `for` (`init` stmt|null, `cond`
expr|null, `inc` expr|null, `body`) · `switch` (`cond`, `body` — cases appear as marker
statements INSIDE the body, preserving Duff-class nesting) · `case` (`v` int64, folded) ·
`default` · `break` · `continue` · `return` (`e`|null) · `goto` (`label`) · `label`
(`name`) · `null`.

## 6. Expressions

`{ "e": <kind>, "t": <result type ref>, ...fields }`. Every node carries its result type.

| e | fields | notes |
|---|---|---|
| `int_lit` | `v` (decimal string, int64 range) | type carries width/signedness |
| `float_lit` | `v` (**hex-float string**, e.g. `"0x1.4p+1"`) | bit-exact, diff-stable |
| `str_lit` | `bytes` [uint8 array, NUL included] | never a JSON string — escape-proof |
| `ref` | `name` | variable/function reference, linkage-resolved name. Binding is by the declaration clang resolved (`referencedDecl.id`, a redeclaration's `previousDecl`), never by spelling: a local that hides a file-scope `static`, or a later block's local named like an earlier block's static local, binds to the local; a block-scope `extern` declares nothing and binds through its file-scope declaration (F47) |
| `enum_ref` | `enum_t`, `item` | kept symbolic for readable output (value is in the type table) |
| `un` | `op`, `a` | ops: `neg plus not bnot preinc predec postinc postdec addr deref` |
| `bin` | `op`, `a`, `b` | ops: `add sub mul div rem shl shr lt gt le ge eq ne band bor bxor land lor` |
| `assign` | `op` (`"" add sub mul div rem shl shr band bor bxor`), `lhs`, `rhs` | compound assigns keep their op |
| `cond` | `c`, `a`, `b` | ternary |
| `comma` | `a`, `b` | |
| `call` | `fn` (expr), `args` [expr] | |
| `member` | `base`, `field` (index into the record's fields), `arrow` (bool) | field by index — rename-proof |
| `index` | `base`, `i` | array or pointer per `base` type |
| `cast` | `kind` (§6.1), `explicit` (bool), `a` | ALL conversions, implicit and explicit |
| `init_list` | `items` [expr], `filler_count_before` per item via `pos` | **semantic positional form**: `items`: `[{ "pos": <index>, "v": expr }]`, unmentioned slots are zero — designators pre-resolved by the dumper |
| `sizeof_v` | `v` (uint64, evaluated), `of_t` (type ref) | value mandatory; `of_t` kept for readable emission |
| `alignof_v` | `v` (uint64, evaluated), `of_t` (type ref) | `_Alignof` / C23 `alignof`, the shape of `sizeof_v` (F54); clang's JSON gives it as a `UnaryExprOrTypeTraitExpr` named `alignof` with the type and no value. GNU `__alignof__` is refused |
| `offsetof` | `of_t` (record type ref), `field` (index into the record's fields) | a direct field of a record (F20). clang's JSON writes an `OffsetOfExpr` with neither its components nor its value, so a dumper reads `T, f` from the macro's text at the expansion site, or from libclang's cursor when a macro body spells the `offsetof`; a member path (`offsetof(T, a.b)`, `offsetof(T, arr[2])`) fails closed |
| `va_arg` | `list` (expr), `arg_t` | |
| `compound_lit` | `t`, `init` (init_list) | |

`"vol": true` (F65): an lvalue node (`ref`, `member`, `index`, `un` `deref`) of
volatile-qualified type carries it after the members of its kind and before `macro`, absent
otherwise. The type table strips qualifiers, and a backend that drops `volatile` changes what
the program does on the optimizing tiers (c-feature-matrix.md, `volatile`).

### 6.1 Pinned castKind enum (v0.1)

Exactly these, spelled as clang 22 spells them; a dumper seeing any other kind fails:

`LValueToRValue` `NoOp` `IntegralCast` `IntegralToFloating` `FloatingToIntegral`
`FloatingCast` `IntegralToBoolean` `FloatingToBoolean` `PointerToBoolean`
`ArrayToPointerDecay` `FunctionToPointerDecay` `NullToPointer` `BitCast`
`PointerToIntegral` `IntegralToPointer` `ToVoid` `BooleanToSignedIntegral`

(`LValueToRValue` and `NoOp` are structural — the backend usually emits nothing for them,
but they stay in the IR: rule 1.)

One normalization (F23): clang spells the decay of a `__builtin_*` function reference
`BuiltinFnToFnPtr`, a kind this list lacks, so every program calling a builtin
(`__builtin_alloca`; 40 gcc-torture tests) would fail closed. A dumper writes it as
`FunctionToPointerDecay`; the callee's name is the one difference. Not a new kind: the IR stays
within the pinned list.

### 6.2 Macro provenance (optional, recovery hook)

Any literal MAY carry `"macro": "MF_SHOOTABLE"` when the dumper can attribute the token
to an object-like macro expansion at that location. Optional per dumper; byte-diff runs
compare with `macro` fields stripped (the one sanctioned normalization).

## 7. Program manifest

```json
{ "cir": "0.1", "target": { ... }, "tus": ["d_main.cir.json", ...],
  "entry": "main" }
```
The backend performs the whole-program merge (cross-TU symbol resolution, SCC module
split) — dumpers never link.

## 8. Canonical serialization (the byte-diff contract)

- UTF-8, LF, no trailing whitespace, file ends with LF.
- Keys emitted in exactly the order this spec lists them per node kind; no extra keys beyond
  the additive members this spec names (`dims`, `"signed"`, `"vol"`), each absent when empty.
- No insignificant whitespace except one space after `:` and `,`; arrays of scalars on
  one line; objects newline-separated with 1-space indent per depth.
- Integers decimal; all floats as hex-float strings; booleans `true`/`false`.
- Type interning order per §2. Producers emitting anything else are non-conforming.

## 9. Out of scope (v0.1)

VLAs, `_Complex`, `_Atomic`, wide strings, inline asm, GNU statement-exprs and nested
functions, `_Generic` (resolved by clang before dump anyway). A dumper hitting one fails
with location (rule 3); the ledger records it. One exception (F74): an asm statement with an empty template, no operand
and no `goto` (clobbers allowed), a compiler barrier such as `asm("")` or
`asm volatile("" ::: "memory")`, dumps as the `null` statement: it orders nothing a das run
observes. Every other asm statement still fails with its location.

## 10. Versioning

`"cir"` is semver-lite: additive fields = minor bump (byte-diff runs pin exact minor);
anything else = major. The castKind list is part of the version.
