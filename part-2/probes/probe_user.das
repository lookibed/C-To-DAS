options gen2
// Two probes of very-detailed-plan.md, run from this folder with `daslang probe_user.das`.
// Splice: prints `x=5 friendly=10` - the wrapper's reader macro spliced `require math`, a
// struct and a function, and this module sees them.
// Cache: the macro prints `[macro ran, value=N]` only when it runs. Run twice (the second
// run is warm and silent), change the number in probe_value.txt, run again (the macro
// runs, the output follows the new number), run once more (warm again).
require probe_wrapper

[export]
def main {
    var s : Imported
    s.x = imported_fn(1)
    print("x={s.x} friendly={friendly(1)}\n")
}
