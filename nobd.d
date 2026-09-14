module nobd;

// nobd.d — dnr-std's build tool: build configuration as a real D program
// instead of Makefile syntax, in the spirit of tsoding/nob.h ("no-build" —
// https://github.com/tsoding/nob.h). `make` still owns the one bootstrapping
// step: it recompiles this file into build/nobd whenever nobd.d changes (see
// the makefile — that's ordinary `$(target): $(prereq)` mtime tracking, the
// one thing make is unambiguously good at) and then hands off. Everything
// else — the file lists, the ldc2 invocations, running the tests — lives
// here, in D, instead of Makefile syntax.
//
// Deliberately self-contained: no `import dnr.*`. If dnr-std itself is
// broken, the tool that builds and tests it must still compile and run —
// the same reasoning nob.h itself is built on nothing but the C standard
// library and the OS.
//
// Usage:
//   build/nobd test     compile the lib + tests to build/test and run it
//   build/nobd check    type-check the library alone (-o-, no codegen)
// (bare `make`, `make test` and `make check` are the usual entry points —
// see the makefile. No argument defaults to `test`.)
//
// ⚠️ Windows only for now, same as the rest of the toolchain (see README.md).
// The Win32 calls below are the minimum CreateProcess needs, hand-declared
// the same way Dopashooter's src/screens.d hand-declares CreateDirectoryA:
// stdcall and C mangle identically on x86_64, our only target, so a plain
// extern(C) + pragma(mangle) links against kernel32 with no
// core.sys.windows.windows import.

import c       = core.stdc.stdio;
import cstring = core.stdc.string;
import cstdlib = core.stdc.stdlib;

// --- Win32: just enough of CreateProcess to spawn ldc2 / the test binary and
// wait for it, plus CreateDirectoryA for the output folder. ------------------

struct StartupInfoA {
    uint cb;
    char* lpReserved;
    char* lpDesktop;
    char* lpTitle;
    uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
    uint dwFillAttribute, dwFlags;
    ushort wShowWindow, cbReserved2;
    ubyte* lpReserved2;
    void* hStdInput, hStdOutput, hStdError;
}
struct ProcessInformation {
    void* hProcess, hThread;
    uint dwProcessId, dwThreadId;
}

extern (C) {
    pragma(mangle, "CreateProcessA")
    int win32_create_process(const(char)* appName, char* cmdLine, void* procAttrs, void* threadAttrs,
                              int inheritHandles, uint creationFlags, void* env, const(char)* curDir,
                              StartupInfoA* startupInfo, ProcessInformation* procInfo);

    pragma(mangle, "WaitForSingleObject")
    uint win32_wait_for_single_object(void* handle, uint millis);

    pragma(mangle, "GetExitCodeProcess")
    int win32_get_exit_code_process(void* handle, uint* exitCode);

    pragma(mangle, "CloseHandle")
    int win32_close_handle(void* handle);

    pragma(mangle, "CreateDirectoryA")
    int win32_create_directory(const(char)* path, void* securityAttrs);
}

enum uint INFINITE_WAIT = 0xFFFF_FFFF;

// --- Cmd: a fixed-capacity argv builder + "spawn it and wait" -------------
//
// A dynamic array would normally be dnr.array.Array!T's job, but this file
// stays free of dnr.* imports on purpose (see the header note) — and a build
// script driving a few dozen file paths has no need for one anyway. Fixed
// capacity, same as every pool in the Dopashooter game this library grew out
// of.

enum size_t MAX_CMD_ARGS = 96;
enum size_t CMDLINE_CAP  = 4096;

struct Cmd {
    const(char)*[MAX_CMD_ARGS] items;
    size_t count = 0;
}

void cmd_add(ref Cmd cmd, const(char)* arg) {
    if (cmd.count >= MAX_CMD_ARGS) {
        c.fprintf(c.stderr, "nobd: too many arguments in one command (raise MAX_CMD_ARGS)\n");
        cstdlib.exit(1);
    }
    cmd.items[cmd.count++] = arg;
}

// Space-joins cmd's argv into `buf` as one Win32 command line (CreateProcess
// takes a single string, not an argv array). Every arg this tool ever builds
// is a plain repo-relative path or compiler flag with no spaces or quoting
// needs, so a naive join is enough — nob.h's own win32 argv-quoting routine
// would be solving a problem we don't have here.
size_t cmd_render(ref Cmd cmd, char[] buf) {
    size_t n = 0;
    foreach (i; 0 .. cmd.count) {
        if (i > 0 && n < buf.length) buf[n++] = ' ';
        size_t len = cstring.strlen(cmd.items[i]);
        foreach (j; 0 .. len) {
            if (n >= buf.length - 1) break;
            buf[n++] = cmd.items[i][j];
        }
    }
    if (n < buf.length) buf[n] = '\0';
    return n;
}

// Echo the command like a shell would before running it, so a failure is easy
// to reproduce by hand. Flushed explicitly: our own stdio is fully buffered
// once it's not attached to a real console (piped through `tail`, a CI log,
// …), but the CHILD's stdout goes straight to the inherited handle, bypassing
// our buffer — without the flush its output can appear before this line does.
void cmd_echo(ref Cmd cmd) {
    c.printf("+");
    foreach (i; 0 .. cmd.count) c.printf(" %s", cmd.items[i]);
    c.printf("\n");
    c.fflush(null);
}

// Spawn `cmd`, wait for it to finish, and report whether it exited 0.
bool cmd_run(ref Cmd cmd) {
    if (cmd.count == 0) return false;
    cmd_echo(cmd);

    char[CMDLINE_CAP] line = void;
    cmd_render(cmd, line[]);

    StartupInfoA si;
    si.cb = StartupInfoA.sizeof;
    ProcessInformation pi;

    if (!win32_create_process(null, line.ptr, null, null, /* inheritHandles */ 1,
                              0, null, null, &si, &pi)) {
        c.fprintf(c.stderr, "nobd: could not start '%s'\n", cmd.items[0]);
        return false;
    }
    win32_close_handle(pi.hThread);
    win32_wait_for_single_object(pi.hProcess, INFINITE_WAIT);
    uint exitCode = 1;
    win32_get_exit_code_process(pi.hProcess, &exitCode);
    win32_close_handle(pi.hProcess);
    return exitCode == 0;
}

// --- the actual build config -----------------------------------------------
// Mirrors the makefile's old LIB_SRC / TEST_SRC exactly. Listed explicitly,
// same discipline as the Dopashooter game's own makefile — no globbing, so
// the file list is never a surprise.

immutable string[] LIB_SRC = [
    "src/dnr/testing.d", "src/dnr/panic.d", "src/dnr/result.d", "src/dnr/mem.d",
    "src/dnr/array.d", "src/dnr/algo.d", "src/dnr/math.d", "src/dnr/rng.d",
    "src/dnr/hash.d", "src/dnr/str.d", "src/dnr/hashmap.d", "src/dnr/io.d",
    "src/dnr/bitset.d", "src/dnr/ringbuf.d", "src/dnr/slotmap.d", "src/dnr/fmt.d",
    "src/dnr/ini.d", "src/dnr/utf8.d", "src/dnr/time.d",
];

immutable string[] TEST_ONLY_SRC = [
    "src/dnr/result_test.d", "src/dnr/mem_test.d", "src/dnr/array_test.d",
    "src/dnr/algo_test.d", "src/dnr/math_test.d", "src/dnr/rng_test.d",
    "src/dnr/hash_test.d", "src/dnr/str_test.d", "src/dnr/hashmap_test.d",
    "src/dnr/panic_test.d", "src/dnr/io_test.d", "src/dnr/bitset_test.d",
    "src/dnr/ringbuf_test.d", "src/dnr/slotmap_test.d", "src/dnr/fmt_test.d",
    "src/dnr/ini_test.d", "src/dnr/utf8_test.d", "src/dnr/time_test.d",
    "src/test_all.d",
];

enum string OUT_DIR = "build";

void cc_flags(ref Cmd cmd) {
    cmd_add(cmd, "ldc2");
    cmd_add(cmd, "-betterC");
    cmd_add(cmd, "-mscrtlib=msvcrt");
}

// `make test` — compile the library + tests to build/test and run it.
bool run_tests() {
    Cmd build;
    cc_flags(build);
    foreach (ref f; LIB_SRC) cmd_add(build, f.ptr);
    foreach (ref f; TEST_ONLY_SRC) cmd_add(build, f.ptr);
    cmd_add(build, "-of");
    cmd_add(build, "build/test");
    if (!cmd_run(build)) return false;

    // ⚠️ CreateProcess (cmd_run, below) won't resolve a bare relative path
    // like "build/test" — confirmed empirically: without a "./" prefix it
    // fails with ERROR_FILE_NOT_FOUND even though the file is right there.
    // Bare names like "ldc2" above are fine; they resolve via the PATH
    // search, which a "./" prefix would break, so this only applies here.
    Cmd run;
    cmd_add(run, "./build/test");
    return cmd_run(run);
}

// `make check` — type-check the library alone, no test files, no codegen.
bool run_check() {
    Cmd cmd;
    cc_flags(cmd);
    cmd_add(cmd, "-o-");
    foreach (ref f; LIB_SRC) cmd_add(cmd, f.ptr);
    return cmd_run(cmd);
}

extern (C) int main(int argc, char** argv) {
    win32_create_directory(OUT_DIR.ptr, null);   // idempotent; "already exists" is fine

    const(char)* command = argc > 1 ? argv[1] : "test";

    if (cstring.strcmp(command, "test") == 0) return run_tests() ? 0 : 1;
    if (cstring.strcmp(command, "check") == 0) return run_check() ? 0 : 1;

    c.fprintf(c.stderr, "nobd: unknown command '%s'\n", command);
    c.fprintf(c.stderr, "usage: nobd [test|check]\n");
    return 1;
}
