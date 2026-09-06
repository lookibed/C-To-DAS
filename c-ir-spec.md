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

## 1. Container

One JSON file per TU: `<name>.cir.json`, UTF-8, LF. A program is a manifest
`program.cir.json` listing TU files plus link-level facts (§7).

Top level of a TU file, exactly these keys in this order:

```json
{
  "cir": "0.1",
  "producer": "c2das-dumper-a 0.1 / clang 22.1.5",
  "target": { "triple": "x86_64-pc-windows-msvc",
              "int": 32, "long": 32, "llong": 64, "ptr": 64, "char_signed": true },
  "tu": "p_mobj.c",
  "types": [ ... ],
  "decls": [ ... ]
}
```

`target` states the dialect the dump was made under (LLP64 default). The backend refuses
mismatched targets across a program.

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
| `struct` / `union` | `name` (or "" anon), `size`, `align`, `packed` (bool), `fields` | field: `{ "name", "t", "off" (byte offset), "bit_off", "bit_w" }` — `bit_off`/`bit_w` present only for bitfields (bit_off is from byte 0 of the record); unnamed bitfield padding appears as `"name": ""` |
| `enum` | `name`, `spell`, `items`: `[{ "name", "v" (int64) }]` | values ALWAYS evaluated; underlying is int32 (dialect) |
| `typedef` | `name`, `to` | kept for readable backend output; semantically transparent |

## 4. Declarations (`decls[]` entries)

| k | fields |
|---|---|
| `global` | `name`, `c_name`, `t`, `static` (bool), `extern` (bool — declaration only, no storage), `init` (expr or null), `loc` |
| `func` | `name`, `c_name`, `t` (func type ref), `static`, `params` [{`name`,`t`}], `body` (compound stmt or null for prototypes), `loc` |
| `record` / `enumdef` / `typedefdecl` | `t` (ref into types[]) — ordering anchors for readable emission, `loc` |

Local statics are hoisted here by the dumper as `global` with `"from_func": "f"`.

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
| `ref` | `name` | variable/function reference, linkage-resolved name |
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
| `va_arg` | `list` (expr), `arg_t` | |
| `compound_lit` | `t`, `init` (init_list) | |

### 6.1 Pinned castKind enum (v0.1)

Exactly these, spelled as clang 22 spells them; a dumper seeing any other kind fails:

`LValueToRValue` `NoOp` `IntegralCast` `IntegralToFloating` `FloatingToIntegral`
`FloatingCast` `IntegralToBoolean` `FloatingToBoolean` `PointerToBoolean`
`ArrayToPointerDecay` `FunctionToPointerDecay` `NullToPointer` `BitCast`
`PointerToIntegral` `IntegralToPointer` `ToVoid` `BooleanToSignedIntegral`

(`LValueToRValue` and `NoOp` are structural — the backend usually emits nothing for them,
but they stay in the IR: rule 1.)

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
- Keys emitted in exactly the order this spec lists them per node kind; no extra keys.
- No insignificant whitespace except one space after `:` and `,`; arrays of scalars on
  one line; objects newline-separated with 1-space indent per depth.
- Integers decimal; all floats as hex-float strings; booleans `true`/`false`.
- Type interning order per §2. Producers emitting anything else are non-conforming.

## 9. Out of scope (v0.1)

VLAs, `_Complex`, `_Atomic`, wide strings, inline asm, GNU statement-exprs and nested
functions, `_Generic` (resolved by clang before dump anyway). A dumper hitting one fails
with location (rule 3); the ledger records it.

## 10. Versioning

`"cir"` is semver-lite: additive fields = minor bump (byte-diff runs pin exact minor);
anything else = major. The castKind list is part of the version.
