# C-To-DAS Part 2 — Acceptance

Part 2 is accepted when every row below passes at one commit of c2das-re, on one pinned
daslang commit. Rows marked **CI** run in continuous integration on every push to `main`;
the others are run once for the acceptance and recorded with their output.

The plan is [very-detailed-plan.md](very-detailed-plan.md); the work items are
[implementation_order.md](implementation_order.md).

## The two examples {#examples}

Both are playground examples: a das program that requires C. The page ships the C sources
as C. The browser compiles them.

| Example | C program | das side |
|---|---|---|
| **Voxel** | `stb_voxel_render.h`, configured by definitions in the import | builds the voxel world, draws the meshes with dasOpenGL, shader written in das |
| **Doom** | PureDOOM, behind `require doom` | the host: frame to the canvas, keyboard, sound, `freedoom2.wad` |

## Frontend {#frontend}

| # | Check | Passes when | |
|---|---|---|---|
| F1 | Own headers under Dumper A | Each suite's pass list and each project's own check hold with `-nostdinc` and the own headers | CI |
| F2 | Token stream | Dumper C's preprocessor output equals `clang -E`'s, token by token, on every suite file and every unit of the eight projects | CI |
| F3 | C-IR, suites | Dumper C's C-IR is byte-identical to Dumper A's on every suite test Dumper A accepts (macro fields stripped) | CI |
| F4 | C-IR, projects | The same on Lua, PureDOOM, doomgeneric, binjgb, h264bsd-mp4, plmpeg-stream, wasm3, quakegeneric | CI |
| F5 | Refusals | Dumper C refuses every suite test Dumper A refuses, with file, line and column | CI |
| F6 | Both dialects | F3 and F4 hold under `linux` and under `msvc` | CI |
| F7 | Suites end to end | With Dumper C, every id of each `expected_pass.txt` passes: c-testsuite, gcc-torture, csmith. The lists are the ones of the commit Part 2 starts from, or longer | CI |

## No clang {#no-clang}

| # | Check | Passes when | |
|---|---|---|---|
| N1 | The lane | A daslang build with dasClangBind off, no clang on `PATH`, runs F7, I1 to I5 and the browser builds of W1 and W2 | CI |
| N2 | The gate | Nothing under `frontend/` or `c_import/` requires `cbind` or spawns a process; the `REVIEW.das` gate fails a change that does | CI |

## Import {#import}

| # | Check | Passes when | |
|---|---|---|---|
| I1 | Suites as imports | Each passing suite test, wrapped in a module with `%c_import`, passes under the interpreter and the JIT | CI |
| I2 | `require doom` | Per-tic checksums of demo1, demo2 and demo3 equal the reference logs under the interpreter, the JIT, the exe and AOT | CI |
| I3 | `require lua` | The Lua test suite passes under the interpreter and the JIT | CI |
| I4 | Definitions | A wrapper with `\| NAME=value` changes what the C code compiles; the same C file under two wrappers with two definition sets gives two results | CI |
| I5 | Cache | On a warm module cache the import does not run. An edit of a C file, of a header it includes, or of the sidecar runs it again. The next run is warm | CI |
| I6 | Errors | A C syntax error and a C type error each stop the compile with the C file, line and column | CI |
| I7 | Text flag | The flag writes the spliced module to disk; c2das-ports regenerates from it | CI |
| I8 | Package | On a clean box, `daspkg` installs the package and the Voxel example runs with no other setup | once |

## Playground {#playground}

| # | Check | Passes when | |
|---|---|---|---|
| W1 | Voxel runs | The Voxel example compiles and draws in the playground | CI, headless browser |
| W2 | Doom runs | The Doom example compiles in the playground and plays demo1; its per-tic checksums equal the reference log | CI, headless browser |
| W3 | Doom is playable | Keyboard input moves the player; sound plays; the frame rate holds Doom's 35 tics per second | once |
| W4 | Live edit, C | An edit of the Voxel example's C text recompiles in the browser and changes the picture | once |
| W5 | Live edit, definitions | An edit of a definition in the import (`STBVOX_CONFIG_MODE`, or one added for the test) recompiles and changes the result | once |
| W6 | Nothing precomputed | The served files of both examples hold C sources and das sources only: no C-IR file, no generated das text of the C program | CI |
| W7 | Compile time | Each example's compile time in the browser is within the bar the owner sets from the preprocessor speed probe (PP.7). The bar is written into this row when it is set | once |
| W8 | Browsers | W1 to W5 pass in every browser the playground supports today | once |

## C coordinates {#c-coordinates}

These rows need the AST backend.

| # | Check | Passes when | |
|---|---|---|---|
| A1 | Two backends agree | Each suite test and each project gives the same output through the text backend and the AST backend, on every tier | CI |
| A2 | AST is the default | I1 to I5, W1 and W2 pass with the AST backend as the import's default | CI |
| A3 | Compile error | A C type error is reported at its C file and line by the daslang compiler's own error list | CI |
| A4 | Panic | A null dereference in C code panics with a stack trace of C files and lines | CI |
| A5 | Debugger | A breakpoint set on a C line stops there, and a step moves to the next C line | once |

## Order {#order}

The rows pass in this order: Frontend, No clang, Import, Playground, C coordinates. The
headline metric of the plan is true when Playground passes. C coordinates close Part 2.
