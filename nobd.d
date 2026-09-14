module nobd;

// nobd.d — dnr-std's build tool: build configuration as a real D program
// instead of Makefile syntax, in the spirit of tsoding/nob.h ("no-build" —
// https://github.com/tsoding/nob.h). `make` still owns the one bootstrapping
// step — recompiling this file into build/nobd whenever nobd.d changes (see
// the makefile — that's ordinary `$(target): $(prereq)` mtime tracking, the
// one thing make is unambiguously good at) and then hands off. Everything
// else — the file lists, the ldc2 invocations, running the tests — lives
// here, in D.
//
// Built on dnr-std's own `dnr.process` (spawn + wait, proper argv quoting)
// and `dnr.fs` (mkdir / needs_rebuild) rather than reimplementing narrower
// versions locally: this file IS dnr-std's build tool, so once those two
// modules exist as general-purpose library pieces in their own right (they
// do — see their own headers and *_test.d), using them here is the natural,
// dogfooding choice. (An earlier version of this file was deliberately
// self-contained instead, to guarantee it could still compile and run even
// if dnr-std itself was broken. That trade-off is still real — a break in
// dnr.process/dnr.fs now breaks nobd's own bootstrap too — but it fails
// LOUDLY, at the `$(OUT)/nobd: nobd.d` compile step, pointing at the exact
// file and line; it's not a silent trap.)
//
// Usage: build/nobd [command]
//   test   (default) build the lib + tests to build/test and run it
//          (skipped and just re-run if build/test is already newer than
//          every source file — see dnr.fs.needs_rebuild)
//   check  type-check the library alone (-o-, no codegen, no main)
//   list   list the available commands
//   help   same as list
//
// ⚠️ Windows only for now — dnr.process / dnr.fs are; see their headers.

import mem     = dnr.mem;
import proc    = dnr.process;
import fs      = dnr.fs;
import res     = dnr.result;
import c       = core.stdc.stdio;
import cstring = core.stdc.string;

enum string OUT_DIR  = "build";
enum string TEST_BIN = "build/test";

// Listed explicitly, same discipline as the Dopashooter game's own makefile
// — no globbing, so the file list is never a surprise.
immutable string[] LIB_SRC = [
    "src/dnr/testing.d", "src/dnr/panic.d", "src/dnr/result.d", "src/dnr/mem.d",
    "src/dnr/array.d", "src/dnr/algo.d", "src/dnr/math.d", "src/dnr/rng.d",
    "src/dnr/hash.d", "src/dnr/str.d", "src/dnr/hashmap.d", "src/dnr/io.d",
    "src/dnr/bitset.d", "src/dnr/ringbuf.d", "src/dnr/slotmap.d", "src/dnr/fmt.d",
    "src/dnr/ini.d", "src/dnr/utf8.d", "src/dnr/time.d", "src/dnr/process.d",
    "src/dnr/fs.d",
];

immutable string[] TEST_ONLY_SRC = [
    "src/dnr/result_test.d", "src/dnr/mem_test.d", "src/dnr/array_test.d",
    "src/dnr/algo_test.d", "src/dnr/math_test.d", "src/dnr/rng_test.d",
    "src/dnr/hash_test.d", "src/dnr/str_test.d", "src/dnr/hashmap_test.d",
    "src/dnr/panic_test.d", "src/dnr/io_test.d", "src/dnr/bitset_test.d",
    "src/dnr/ringbuf_test.d", "src/dnr/slotmap_test.d", "src/dnr/fmt_test.d",
    "src/dnr/ini_test.d", "src/dnr/utf8_test.d", "src/dnr/time_test.d",
    "src/dnr/process_test.d", "src/dnr/fs_test.d", "src/test_all.d",
];

void cc_base(ref proc.Cmd cmd) {
    proc.cmd_add(cmd, "ldc2");
    proc.cmd_add(cmd, "-betterC");
    proc.cmd_add(cmd, "-mscrtlib=msvcrt");
}

// true if `output` is missing or older than any file in `lista`/`listb`.
// Takes two lists (rather than one combined one) so callers don't need to
// build a merged array just to ask the question — see run_tests below.
// Any per-file error (a source genuinely missing, say) is treated as "yes,
// rebuild" — the compiler is what should explain why, not this check.
bool any_stale(const(char)[] output, immutable string[] lista, immutable string[] listb) @nogc nothrow {
    foreach (f; lista) {
        auto r = fs.needs_rebuild1(output, f);
        if (r.is_err || r.unwrap) return true;
    }
    foreach (f; listb) {
        auto r = fs.needs_rebuild1(output, f);
        if (r.is_err || r.unwrap) return true;
    }
    return false;
}

// `test` (default) — compile the library + tests to build/test (skipping the
// compile if nothing changed) and run it.
bool run_tests(mem.Allocator a) {
    if (any_stale(TEST_BIN, LIB_SRC, TEST_ONLY_SRC)) {
        auto build = proc.cmd_make(a);
        cc_base(build);
        foreach (f; LIB_SRC) proc.cmd_add(build, f);
        foreach (f; TEST_ONLY_SRC) proc.cmd_add(build, f);
        proc.cmd_add(build, "-of");
        proc.cmd_add(build, TEST_BIN);
        auto r = proc.cmd_run(build);
        proc.cmd_free(build);
        if (r != proc.ProcessResult.ok) return false;
    } else {
        c.printf("nobd: %.*s is up to date, skipping the compile\n",
                 cast(int) TEST_BIN.length, TEST_BIN.ptr);
    }

    auto run = proc.cmd_make(a);
    proc.cmd_add(run, TEST_BIN);
    auto r = proc.cmd_run(run);
    proc.cmd_free(run);
    return r == proc.ProcessResult.ok;
}

// `check` — type-check the library alone, no test files, no codegen.
bool run_check(mem.Allocator a) {
    auto cmd = proc.cmd_make(a);
    cc_base(cmd);
    proc.cmd_add(cmd, "-o-");
    foreach (f; LIB_SRC) proc.cmd_add(cmd, f);
    auto r = proc.cmd_run(cmd);
    proc.cmd_free(cmd);
    return r == proc.ProcessResult.ok;
}

private struct CommandInfo { string name; string desc; }
private immutable CommandInfo[] COMMANDS = [
    CommandInfo("test",  "compile the lib + tests to build/test and run it (default)"),
    CommandInfo("check", "type-check the library alone (-o-, no codegen)"),
    CommandInfo("list",  "list the available commands"),
    CommandInfo("help",  "same as list"),
];

void print_commands() {
    c.printf("nobd — dnr-std's build tool. Available commands:\n");
    foreach (cmd; COMMANDS)
        c.printf("  %-6.*s %.*s\n",
                 cast(int) cmd.name.length, cmd.name.ptr,
                 cast(int) cmd.desc.length, cmd.desc.ptr);
}

extern (C) int main(int argc, char** argv) {
    auto a = mem.malloc_allocator();
    fs.mkdir_if_not_exists(OUT_DIR);   // idempotent; every command wants it

    const(char)* command = argc > 1 ? argv[1] : "test";

    if (cstring.strcmp(command, "test") == 0)  return run_tests(a) ? 0 : 1;
    if (cstring.strcmp(command, "check") == 0) return run_check(a) ? 0 : 1;
    if (cstring.strcmp(command, "list") == 0 || cstring.strcmp(command, "help") == 0) {
        print_commands();
        return 0;
    }

    c.fprintf(c.stderr, "nobd: unknown command '%s'\n", command);
    print_commands();
    return 1;
}
