options gen2
module probe_wrapper public
require c_probe_macro

%c_probe~ foo.h | DEF=1 %%

def friendly(a : int) : int {
    return imported_fn(a) * 2
}
