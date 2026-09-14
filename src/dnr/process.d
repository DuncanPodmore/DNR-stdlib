module dnr.process;

// ---------------------------------------------------------------------------
// process — spawn a child process, wait for it, read its exit code
// ---------------------------------------------------------------------------
// A Cmd is a growable argv list (dnr.array.Array!(const(char)[])); build one
// with cmd_add, then cmd_run it. The shape mirrors tsoding/nob.h's Nob_Cmd /
// cmd_run, ported to D + betterC — see nobd.d (dnr-std's own build tool,
// repo root) for the motivating use case.
//
//   auto a = mem.malloc_allocator();
//   auto cmd = cmd_make(a);
//   cmd_add(cmd, "ldc2"); cmd_add(cmd, "-betterC"); cmd_add(cmd, "foo.d");
//   int code;
//   if (cmd_run(cmd, RunOpt.init, &code) != ProcessResult.ok) { ... }
//   cmd_free(cmd);
//
// Output redirection goes to a FILE PATH (`RunOpt.stdoutPath`/`stderrPath`),
// not an in-memory pipe: a child that outpaces an unread pipe buffer can
// deadlock against a parent that's blocked waiting for it to exit, and
// nob.h itself sidesteps that by redirecting to a path and reading it back
// afterwards (see its own test runner) — same trade here.
//
// ⚠️ Windows only for now (CreateProcess-based). The version(Posix) branch
// has the right signatures so callers type-check on any platform, but its
// bodies are `dnr.panic.todo()` — fork/execvp is a real implementation this
// project hasn't needed yet, not a design gap.

import mem = dnr.mem;
import arr = dnr.array;
import str = dnr.str;
import res = dnr.result;
import pan = dnr.panic;

// ===========================================================================
// Cmd — the argv builder
// ===========================================================================

struct Cmd {
    arr.Array!(const(char)[]) items;
}

Cmd cmd_make(mem.Allocator a, size_t reserve = 0) @nogc nothrow {
    return Cmd(arr.array_make!(const(char)[])(a, reserve));
}

void cmd_free(ref Cmd cmd) @nogc nothrow { arr.array_free(cmd.items); }

// Length back to 0, capacity kept — for reusing one Cmd across several runs.
void cmd_clear(ref Cmd cmd) @nogc nothrow { arr.array_clear(cmd.items); }

size_t cmd_len(ref const Cmd cmd) @nogc nothrow { return arr.array_len(cmd.items); }

res.Status cmd_add(ref Cmd cmd, const(char)[] arg) @nogc nothrow {
    return arr.array_push(cmd.items, arg);
}

// Append several at once (e.g. a module's file list). `StdErr.oom` on
// failure — the Cmd is left with whatever fit before the failing element,
// same as array_append's semantics on any single reallocation failure.
res.Status cmd_add_all(ref Cmd cmd, const(char)[][] args) @nogc nothrow {
    foreach (a; args) {
        auto s = cmd_add(cmd, a);
        if (s.is_err) return s;
    }
    return res.pass();
}

// Render `cmd` space-joined into `sb`, for logging — e.g. "+ ldc2 -betterC
// foo.d" the way a shell would echo it. Not re-parseable; see
// win32_quote_arg for the string that's actually passed to CreateProcess.
void cmd_echo(ref Cmd cmd, ref str.Sb sb) @nogc nothrow {
    foreach (i, a; cmd.items.items) {
        if (i > 0) str.sb_put_char(sb, ' ');
        str.sb_put(sb, a);
    }
}

// ===========================================================================
// spawning
// ===========================================================================

enum ProcessResult : ubyte {
    ok,           // spawned, ran to completion, exited 0
    failed,       // spawned, ran to completion, exited non-zero
    spawn_error,  // could not even start (bad path, OS refused, ...)
}

struct RunOpt {
    bool echo = true;              // print "+ <cmd>" to stdout before running
    const(char)[] stdoutPath;      // empty = inherit the console
    const(char)[] stderrPath;      // empty = inherit the console
}

version (Windows) {

private import cstdio = core.stdc.stdio;

alias ProcHandle = void*;
enum ProcHandle INVALID_PROC = null;

private struct StartupInfoA {
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
private struct ProcessInformation {
    void* hProcess, hThread;
    uint dwProcessId, dwThreadId;
}
private struct SecurityAttributes {
    uint nLength;
    void* lpSecurityDescriptor;
    int bInheritHandle;
}

private enum uint STARTF_USESTDHANDLES = 0x0100;
private enum uint INFINITE_WAIT        = 0xFFFF_FFFF;
private enum uint GENERIC_WRITE        = 0x4000_0000;
private enum uint FILE_SHARE_READ      = 1;
private enum uint FILE_SHARE_WRITE     = 2;
private enum uint CREATE_ALWAYS        = 2;
private enum uint FILE_ATTRIBUTE_NORMAL = 0x80;
private void* INVALID_HANDLE_VALUE() @nogc nothrow { return cast(void*)(-1); }

private enum uint STD_INPUT_HANDLE  = 0xFFFF_FFF6;
private enum uint STD_OUTPUT_HANDLE = 0xFFFF_FFF5;
private enum uint STD_ERROR_HANDLE  = 0xFFFF_FFF4;

extern (C) {
    pragma(mangle, "CreateProcessA")
    private int win32_CreateProcessA(const(char)* appName, char* cmdLine, void* procAttrs, void* threadAttrs,
                                      int inheritHandles, uint creationFlags, void* env, const(char)* curDir,
                                      StartupInfoA* startupInfo, ProcessInformation* procInfo) @nogc nothrow;
    pragma(mangle, "WaitForSingleObject")
    private uint win32_WaitForSingleObject(void* handle, uint millis) @nogc nothrow;
    pragma(mangle, "GetExitCodeProcess")
    private int win32_GetExitCodeProcess(void* handle, uint* exitCode) @nogc nothrow;
    pragma(mangle, "CloseHandle")
    private int win32_CloseHandle(void* handle) @nogc nothrow;
    pragma(mangle, "CreateFileA")
    private void* win32_CreateFileA(const(char)* name, uint access, uint share, SecurityAttributes* sa,
                                     uint disposition, uint flags, void* templateFile) @nogc nothrow;
    pragma(mangle, "GetStdHandle")
    private void* win32_GetStdHandle(uint stdHandle) @nogc nothrow;
    pragma(mangle, "GetLastError")
    uint win32_get_last_error() @nogc nothrow;
}

// Space-joins + MSVCRT-quotes cmd's argv into one Win32 command line (a
// single string is what CreateProcess actually takes). Ported from
// nob.h's nob__win32_cmd_quote — the documented CommandLineToArgvW-compatible
// algorithm: unquoted unless an arg has whitespace or a '"', doubled
// argv[0] specifically: CreateProcess (with lpApplicationName == NULL, which
// is how we always call it) will NOT resolve a relative path that contains a
// directory separator — confirmed empirically, both "build/test" and
// "build\test" fail with ERROR_FILE_NOT_FOUND even though the file is right
// there — unless it's prefixed "./" (or already absolute, or a bare PATH-
// searched name like "ldc2" with no separator at all, which is unaffected).
// win32_quote_cmd adds the prefix automatically so no caller has to
// remember this.
private bool win32_needs_dot_prefix(const(char)[] arg0) @nogc nothrow {
    bool hasSep = false;
    foreach (c; arg0) if (c == '/' || c == '\\') { hasSep = true; break; }
    if (!hasSep) return false;                                             // bare name: PATH search, fine
    if (arg0.length >= 2 && arg0[1] == ':') return false;                  // "C:\..." absolute
    if (arg0.length >= 2 && arg0[0] == '.' && (arg0[1] == '/' || arg0[1] == '\\')) return false; // already "./" / ".\"
    if (arg0.length >= 2 && arg0[0] == '\\' && arg0[1] == '\\') return false; // "\\server\share" UNC
    return true;
}

private void win32_quote_one(ref str.Sb sb, const(char)[] a, bool dotPrefix) @nogc nothrow {
    bool needsQuote = a.length == 0;
    if (!needsQuote) foreach (c; a) if (c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '"') { needsQuote = true; break; }

    if (!needsQuote) {
        if (dotPrefix) { str.sb_put_char(sb, '.'); str.sb_put_char(sb, '/'); }
        str.sb_put(sb, a);
        return;
    }

    str.sb_put_char(sb, '"');
    if (dotPrefix) { str.sb_put_char(sb, '.'); str.sb_put_char(sb, '/'); }
    size_t backslashes = 0;
    foreach (c; a) {
        if (c == '\\') {
            backslashes++;
        } else {
            if (c == '"') foreach (_; 0 .. backslashes + 1) str.sb_put_char(sb, '\\');
            backslashes = 0;
        }
        str.sb_put_char(sb, c);
    }
    foreach (_; 0 .. backslashes) str.sb_put_char(sb, '\\');
    str.sb_put_char(sb, '"');
}

void win32_quote_cmd(ref Cmd cmd, ref str.Sb sb) @nogc nothrow {
    foreach (i, a; cmd.items.items) {
        if (i > 0) str.sb_put_char(sb, ' ');
        win32_quote_one(sb, a, i == 0 && win32_needs_dot_prefix(a));
    }
}

// Open `path` as an inheritable, write-only handle for stdout/stderr
// redirection (CREATE_ALWAYS: truncate/create). null on failure.
private void* open_redirect_target(const(char)[] path, ref char[1024] cpath) @nogc nothrow {
    if (path.length == 0 || path.length >= cpath.length) return null;
    foreach (i, c; path) cpath[i] = c;
    cpath[path.length] = 0;
    SecurityAttributes sa;
    sa.nLength = SecurityAttributes.sizeof;
    sa.bInheritHandle = 1;
    void* h = win32_CreateFileA(cpath.ptr, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    return h == INVALID_HANDLE_VALUE() ? null : h;
}

// Spawn without waiting. INVALID_PROC on failure (nothing to wait for).
ProcHandle cmd_run_async(ref Cmd cmd, RunOpt opt = RunOpt.init) @nogc nothrow {
    if (arr.array_len(cmd.items) == 0) return INVALID_PROC;

    if (opt.echo) {
        char[4096] buf = void;
        auto sb = str.sb_fixed(buf[]);
        str.sb_put(sb, "+ ");
        cmd_echo(cmd, sb);
        cstdio.printf("%.*s\n", cast(int) str.sb_len(sb), str.sb_slice(sb).ptr);
        cstdio.fflush(null);   // our buffered stdout must land before the child's does
    }

    // The last byte of lineBuf is deliberately withheld from the Sb, so
    // sb_len(lineSb) can never exceed lineBuf.length - 1 and the NUL write
    // below is always in-bounds — even if the rendered command line is long
    // enough for sb_fixed to truncate it.
    char[8192] lineBuf = void;
    auto lineSb = str.sb_fixed(lineBuf[0 .. $ - 1]);
    win32_quote_cmd(cmd, lineSb);
    lineBuf[str.sb_len(lineSb)] = '\0';

    StartupInfoA si;
    si.cb = StartupInfoA.sizeof;
    ProcessInformation pi;

    // Redirecting at all means EVERY std handle must be explicit — leaving
    // one null under STARTF_USESTDHANDLES gives the child a closed handle,
    // not "inherit the console", for that stream.
    char[1024] outPath = void, errPath = void;
    void* hOut = open_redirect_target(opt.stdoutPath, outPath);
    void* hErr = open_redirect_target(opt.stderrPath, errPath);
    if (opt.stdoutPath.length || opt.stderrPath.length) {
        si.dwFlags |= STARTF_USESTDHANDLES;
        si.hStdInput  = win32_GetStdHandle(STD_INPUT_HANDLE);
        si.hStdOutput = hOut ? hOut : win32_GetStdHandle(STD_OUTPUT_HANDLE);
        si.hStdError  = hErr ? hErr : win32_GetStdHandle(STD_ERROR_HANDLE);
    }

    int ok = win32_CreateProcessA(null, lineBuf.ptr, null, null, /* inheritHandles */ 1,
                                  0, null, null, &si, &pi);
    if (hOut) win32_CloseHandle(hOut);
    if (hErr) win32_CloseHandle(hErr);
    if (!ok) return INVALID_PROC;

    win32_CloseHandle(pi.hThread);
    return pi.hProcess;
}

// Wait for a process cmd_run_async started. true if it exited 0. `exitCode`
// (optional) receives the real code either way; left untouched on a wait
// failure.
bool proc_wait(ProcHandle p, int* exitCode = null) @nogc nothrow {
    if (p is INVALID_PROC) return false;
    win32_WaitForSingleObject(p, INFINITE_WAIT);
    uint code = 1;
    win32_GetExitCodeProcess(p, &code);
    win32_CloseHandle(p);
    if (exitCode) *exitCode = cast(int) code;
    return code == 0;
}

} else version (Posix) {

alias ProcHandle = int;   // pid_t
enum ProcHandle INVALID_PROC = -1;

ProcHandle cmd_run_async(ref Cmd cmd, RunOpt opt = RunOpt.init) @nogc nothrow {
    pan.todo("dnr.process.cmd_run_async: POSIX (fork/execvp) not implemented yet");
}

bool proc_wait(ProcHandle p, int* exitCode = null) @nogc nothrow {
    pan.todo("dnr.process.proc_wait: POSIX (waitpid) not implemented yet");
}

} else {
    static assert(false, "dnr.process: unsupported platform");
}

// Spawn + wait in one call — the common case.
ProcessResult cmd_run(ref Cmd cmd, RunOpt opt = RunOpt.init, int* exitCode = null) @nogc nothrow {
    auto p = cmd_run_async(cmd, opt);
    if (p is INVALID_PROC) return ProcessResult.spawn_error;
    bool ok = proc_wait(p, exitCode);
    return ok ? ProcessResult.ok : ProcessResult.failed;
}
