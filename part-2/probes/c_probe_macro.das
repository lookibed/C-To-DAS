options gen2
module c_probe_macro shared private

require daslib/ast public
require daslib/ast_boost public
require strings
require daslib/fio

def private accept_until_double_percent(var expr : ExprReader?; ch : int) : bool {
    if (ch != '\r') {
        append(expr.sequence, ch)
    }
    if (ends_with(expr.sequence, "%%")) {
        let len = length(expr.sequence)
        resize(expr.sequence, len - 2)
        return false
    } else {
        return true
    }
}

[reader_macro(name="c_probe")]
class CProbeReader : AstReaderMacro {
    def override accept(prog : ProgramPtr; mod : Module?; var expr : ExprReader?; ch : int; info : LineInfo) : bool =>
        accept_until_double_percent(expr, ch)
    def override suffix(prog : ProgramPtr; mod : Module?; var expr : ExprReader?; info : LineInfo; var outLine : int&; var outFile : FileInfo?&) : string {
        outLine = int(info.line)
        let path = path_join(dir_name(string(info.fileInfo.name)), "probe_value.txt")
        add_module_cache_dependency(path)
        var value = "0"
        fopen(path, "rb") $(f) {
            if (f != null) {
                value = strip(fread(f))
            }
        }
        print("[macro ran, value={value}]\n")
        return "\nrequire math\nstruct Imported \{\n    x : int\n\}\ndef imported_fn(a : int) : int \{\n    return a + {value}\n\}\n"
    }
}
