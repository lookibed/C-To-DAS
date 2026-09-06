# C-To-DAS — Implementation Order

The execution plan for the `c2das` project, expanded from [very-detailed-plan.md](very-detailed-plan.md)
§9 into concrete, ordered work items. Read it with the normative companions open:
[lowering-examples.md](lowering-examples.md) and [stdlib-examples.md](stdlib-examples.md)
contain the *expected output code* for every construct — most work items below are
"transcribe the spec into the emitter", not design work. [c-feature-matrix.md](c-feature-matrix.md)
is the coverage checklist; [sidequest.md](sidequest.md) lists daslang-core follow-ups that
never block this plan.

**Working rules for the implementer**
1. The docs are normative. When your code and the docs disagree, one of them is a bug —
   stop and resolve it deliberately (usually with a probe), never silently diverge.
2. Probe before assuming. Every ✓ in the docs was verified on a live binary on 2026-08-21;
   re-run the probes suite (P0.3) on your binary before trusting them. A probe that
   contradicts the docs is a finding — report it, don't work around it.
3. Ratchet discipline: suite pass-counts only go up. Every skip gets a ledger line
   (feature, reason, phase that unblocks it). No silent exclusions.
4. Fixtures before machinery: every c_runtime piece and every lowering lands with a
   hand-written "as-if-converted" `.das` test first, converter integration second.
5. No hand edits to converted output, ever. Per-project judgment goes in the sidecar.

---

## Where to get everything

Pin exact versions in the repo (a `VERSIONS.md` or the fetch scripts themselves); never
"latest". URLs are the projects' stable homes — all long-lived.

| What | Where | Notes |
|---|---|---|
| daslang | https://github.com/GaijinEntertainment/daScript | build with dasClangBind enabled; dastest, dasImgui, dasAudio, MCP/LSP all in-tree — no separate downloads |
| LLVM/libclang 22.1.5 | https://github.com/llvm/llvm-project/releases — the `clang+llvm-22.1.5-x86_64-pc-windows-msvc` archive | must be the layout WITH `lib/cmake/clang` (the .exe installer lacks it); point `Clang_DIR` at it |
| PureDOOM | https://github.com/Daivuk/PureDOOM | GPL-2 — vendor under `doom/`, never mix into MIT dirs; single-header or `src/DOOM` multi-file, we convert the multi-file form |
| doomgeneric (reference only) | https://github.com/ozkl/doomgeneric | the canonical fallback if PureDOOM surprises us; not vendored by default |
| freedoom2.wad | https://freedoom.github.io/download.html (releases: https://github.com/freedoom/freedoom/releases) | BSD-licensed — the CI wad, fetched by script |
| doom2.wad | commercial — DOOM II on Steam or GOG | user-supplied, local only, NEVER committed or fetched |
| c-testsuite | https://github.com/c-testsuite/c-testsuite | single-file tests + `.expected` outputs; the V1 gate |
| GCC c-torture `execute` | https://github.com/gcc-mirror/gcc — subtree `gcc/testsuite/gcc.c-torture/execute`, pin a release tag (e.g. `releases/gcc-14.2.0`) | fetch script sparse-checkouts just the subtree |
| csmith | https://github.com/csmith-project/csmith | build from source; runs fine under WSL if the Windows build fights back |
| creduce / cvise | https://github.com/csmith-project/creduce · https://github.com/marxin/cvise | divergence minimizers (P4.5); cvise is the better-maintained choice, WSL |
| Lua 5.4 | https://www.lua.org/ftp/ (pin e.g. `lua-5.4.8.tar.gz`) + matching test suite from https://www.lua.org/tests/ | MIT; the test tarball is versioned — match it to the source tarball exactly |
| GM soundfont (Doom music) | GeneralUser GS — https://schristiancollins.com/generaluser.php | free license, the standard choice; any GM-complete .sf2/.sf3 works with dasAudio's player |

## P0 — Bootstrap

**Goal: the walking skeleton — every tool in the chain touched once.**

- **P0.1 Repo skeleton.** `c2das` external repo: `converter/`, `c_runtime/` (das),
  `dasCRuntime/` (C++ glue module), `probes/`, `suites/`, `doom/`, `lua/`, `docs/`
  (these six documents move in). License split: repo MIT/BSD, `doom/` subtree GPL-2.
- **P0.2 daslang dependency.** Consume a daslang build with dasClangBind enabled
  (libclang 22.1.5; `Clang_DIR`/`PATH_TO_LIBCLANG` resolves — works on MSVC). Standard
  external-module worktree pattern; MCP bootstrap for the working tree.
- **P0.3 Probes suite.** Port every probe from the plan's discussion into `probes/` as a
  dastest suite (~25 probes, all already written — they live in the docs and this repo's
  history). This is the das-facts regression net: it runs first in CI, and a probe
  failure after a daslang update is a *finding*, not noise.
  Acceptance: all probes green on the pinned daslang build.
- **P0.4 dasCRuntime v1.** The native glue module: CRT binds for malloc family, mem*,
  string.h list, libm exotica, errno accessors, time/clock, rand/srand, getenv, snprintf.
  `addExtern` lines only — no logic. Name policy per stdlib-examples.md (crt namespace).
  Acceptance: a das test calls each bind and checks a known value.
- **P0.5 C-IR spec + converter skeleton.** Write `c-ir-spec.md` — the versioned
  interchange contract (plan §4.0): types with layout baked in, pinned castKind enum,
  evaluated constants, positional initializers. Then the skeleton: a C-IR reader + das
  emitter for the trivial subset (main, return, integer literals), fed by **Dumper A**
  (`clang -ast-dump=json` + dasClangBind layout, thin normalizer). Dumper B (the C2Rust
  fork serializing C-IR) is a parallel track owned by its author; the byte-diff harness
  between dumpers lands as soon as both exist. Formatter + `compile_check` wired into the
  pipeline from day one.
- **P0.6 Exit criterion (the P0 gate).** `int main(){return 42;}` converts, compiles,
  and returns 42 under **interp, JIT, and AOT** (this run also closes the goto-tier
  confirmation — both emitters carry ExprGoto handlers, source-verified).

## P1 — c_runtime semantic layer + expression/statement core

**Goal: the language core over scalars, and the entire c_runtime, each tested standalone.**

Order matters: c_runtime first (it's converter-independent — fixtures are hand-written
"as-if-converted" das), then the suite runner, then the lowerings climb the ratchet.

- **P1.1 `[c_function]`.** ~15-line macro (spec + precedent in lowering-examples.md).
- **P1.2 `enum_from_int`, `c_exit`/`c_abort`/atexit (`[finalize]` walker), `cstr_array`
  macro.** All spec'd; atexit LIFO + exit()-path behavior probed.
- **P1.3 `[variadic]` machinery.** `to_cvalist` (code is in lowering-examples.md,
  probed), the call macro that tuples trailing args (probed), the packaging decision
  (annotation-registered vs converter-emitted per-function classes — try annotation
  first, fall back without ceremony), empty/1-element tuple cases.
- **P1.4 printf.** Format splitter + per-directive CRT `snprintf` calls; `c_vprintf` as
  the same splitter at runtime over a CVaList. Fixture: byte-diff against native printf
  output for a conversion battery (this fixture is also the differential-suite
  insurance policy).
- **P1.5 Suite runner + ratchet.** `suites/` fetches c-testsuite; runner converts, runs
  interp, diffs expected output and exit codes; ratchet state checked in; skip ledger.
  Acceptance: runner executes end-to-end on the P0-subset tests (however few pass).
- **P1.6 Lowerings, in spec order:** promotions/usual-arithmetic-conversions pass
  (emit-explicit-casts; small-int promote/truncate), statement-ification (temps,
  ++/--, comma, side-effecting &&/||/?:), all operators and the cast table, if/while
  (1:1), do-while (first-pass flag), general for (increment-first flag; O1 range-form
  recognition can wait for P7), scalar functions and locals/globals, `exit`.
  Each item = spec section + fixtures + ratchet delta.
- **P1.7 Profile race** (small, deferrable to P7): for-loop B' vs body-block `finally`.
- **Exit criterion:** c-testsuite scalar/control-flow tests green; ratchet
  infrastructure proven; c_runtime tests green standalone.

## P2 — Aggregates, pointers, enums, strings, globals

**Goal: the memory model — everything the layout law licenses.**

- **P2.1 Structs.** Layout read-out from clang (assert equal to das `typeinfo` for
  unpacked types — the layout law is probed, keep the assert anyway), plain-`=` copies,
  by-value param callee-copies (only when written), returns, prefix punning,
  `sizeof`/`offsetof` → `typeinfo` emission.
- **P2.2 Arrays.** Exact-size `fixed_array` literals (pad or decl+assign per spec),
  multi-dim, row pointers (`T[3]?` — mind `? [` spacing), decay, OOB-panic policy +
  sidecar demotion hook.
- **P2.3 Pointers + `[c_function]` application.** The cast table; annotate only
  functions containing unsafe ops (the count is the port-progress metric — report it).
- **P2.4 Enums.** das enums per spec (casts at arithmetic/relational/index sites,
  `enum_from_int`, count-as-dim).
- **P2.5 Strings.** Literal policy (das literal reinterpret for `char*`, `cstr_array`
  for mutable `char[]`), interning, the `reinterpret<string>` bridge at logging sites.
- **P2.6 Globals & statics.** Zero-init pass-through, value inits at declaration,
  address-carrying inits inline-where-legal else `[init]`, statics naming, `var private`.
- **P2.7 Marshal-reader generator.** For packed/disk types from clang's packed layout
  (sidecar-flagged types only at this stage).
- **P2.8 gcc-torture `execute` import.** Filter script + ledger; ratchet begins.
- **Exit criterion:** c-testsuite ≥ 90% of applicable; torture ratchet climbing;
  struct/array/pointer sections green.

## P3 — Control-flow completeness

**Goal: everything that jumps.**

- **P3.1 switch.** Tier 1 if/elif (no fallthrough, tail-only breaks), tier 2
  matched-flag loop (fully spec'd + probed, incl. `_cont` epilogue), tier detection.
- **P3.2 goto.** Label allocation, C-names-as-comments, goto-into-nested-block
  flattening, goto-over-declaration (C-exact semantics probed — nothing to do, but add
  the fixture).
- **P3.3 Duff's device.** The state-machine fallback — this is the one place you get to
  design; write the spec into lowering-examples.md first, get it reviewed, then build.
- **P3.4 setjmp/longjmp.** The try/recover + `_c_jmp_target` protocol (fully probed);
  contained pattern first, general trampoline second.
- **P3.5 alloca.** das-stack fixed arena + limit guard + `options stack` sizing in the
  sidecar; torture's alloca tests join the ratchet.
- **Exit criterion:** torture control-flow and alloca sections green; no goto-family
  ledger entries left except Duff-class (if any survive, they're state-machine bugs).

## P4 — Punning tier + differential fuzzing

**Goal: the last semantic mile, then the truth cannon.**

- **P4.1 `[c_bitfields]` macro.** Generates the probed backing-unit + property-operator
  layer from clang bit offsets; fixtures replicate the probe battery (signed sign-extend,
  truncation, compound assign, layout).
- **P4.2 `[c_union]` macro.** One ref-returning operator per member (probed); storage
  alignment via max-align member type; anonymous-union flattening.
- **P4.3 Function-pointer shims.** The sidecar-declared dispatch groups (`actionf_t`
  class); qsort/bsearch typed generics land here too.
- **P4.4 va_list completeness.** `va_copy`, forwarding, non-constant printf formats,
  scanf-family split.
- **P4.5 csmith differential.** Nightly N=1000 seeds vs `gcc -O0 -fwrapv`; any
  divergence is a converter bug by construction; creduce harness for minimization.
- **Exit criterion:** csmith runs clean at 1000/night for a week; torture ≥ target with
  ledger; matrix has no row without a green fixture.

## P5 — Lua 5.4

**Goal: first real program, and a semantic oracle bigger than all suites combined.**

- **P5.1 Whole-program conversion** of lua + luac (single module or SCC split — first
  real data point on das compile time at scale; measure and report).
- **P5.2 pcall** via the setjmp lowering (`LUAI_THROW/LUAI_TRY` → `c_longjmp`/contained
  pattern — the easy shape, per spec).
- **P5.3 Lua's own test suite** under interp. Expect a long tail of libc exactness bugs
  (strtod, number formatting, string.format) — each fix lands with a fixture.
- **P5.4 Perf snapshot:** fib/nbody/binary-trees, converted-interp vs native lua. Data
  point only; no bar.
- **Exit criterion:** Lua test suite passes under interp; JIT/AOT lanes at least compile
  and run the benchmarks.

## P6 — Doom

**Goal: the metric.**

- **P6.1 PureDOOM import.** Vendored, sidecar authored (defines, marshal types for WAD
  structs, `actionf_t` shim group, alloca/stack sizing). Instrumentation patch: per-tic
  checksum (players[0].mo x/y/z/angle/health + P_Random index) — applied to the C
  source, so the native build and the converted build share it by construction.
- **P6.2 Native baseline build** (MSVC /O2) with instrumentation; record reference
  checksum logs for demo1/2/3 on freedoom2.wad and doom2.wad.
- **P6.3 Converts + compiles.** First real whole-program stress after Lua; expect
  module-size issues here if anywhere (SCC split is the tool).
- **P6.4 Boots headless.** `D_DoomMain` to attract screen; framebuffer CRC at fixed
  tics vs native.
- **P6.5 Demo sync.** The ladder: first desynced tic → bisect → fix → repeat until
  demo1/2/3 are 100% on both wads. This is the semantics endgame; every desync is a
  real bug with a tic number attached.
- **P6.6 Playable harness.** dasImgui window (framebuffer texture blit, key mapping),
  PCM SFX to the native audio path, MIDI music via dasAudio strudel_midi_player + GM
  soundfont.
- **P6.7 timedemo.** `-timedemo demo3` realtics for native / interp; publish table v1.
- **Exit criterion:** demo-sync 100%, playable with sound and music, perf table v1.

## P7 — Performance + tiers

**Goal: the 35 fps interp bar and the full table.**

- **P7.1 O1 range-loop rewrite** (unlocks automatic bound-check elision), **O2
  `[unsafe_deref]`**, **O3 `[hint(unsafe_range_check)]`** — sidecar-gated, enabled only
  after demo-sync green, re-verify sync after enabling.
- **P7.2 Profile** the renderer inner loops (R_DrawColumn/R_DrawSpan expected); apply
  O4/O5/O6 only where the profile demands.
- **P7.3 JIT + AOT lanes** green across suites, Lua, Doom; timedemo columns filled.
- **P7.4 The bar:** interp ≥ 35 fps at 320×200 (30 accepted floor). Then the writeup.
- **Exit criterion:** the §2 metric sentence of the plan is true, all four columns
  published.

---

## Standing dependencies

- P1 c_runtime items are converter-independent — they can proceed in parallel with P0.5.
- The suite runner (P1.5) blocks all ratchet claims — build it before deep lowering work.
- `[c_bitfields]`/`[c_union]` (P4) depend only on P1 macros, not on P2/P3 — they can be
  pulled earlier if the macro appetite is there.
- Nothing depends on any sidequest.md item; if one lands early (e.g. `[pack]`), swap the
  fallback out behind the sidecar flag.
