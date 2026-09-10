module dnr.panic;

// ---------------------------------------------------------------------------
// panic — fail loudly and stop
// ---------------------------------------------------------------------------
// betterC keeps `assert` (it calls the C runtime's assert handler), but there
// is no `throw`, no stack trace, and no way to attach a message to a bare
// `assert(0)`. These are the "this should never happen, and if it did I want
// to know exactly where" helpers:
//
//   panic(msg)        — an unrecoverable error
//   unreachable()     — a branch the logic says can't be taken
//   todo()            — a hole you haven't filled yet
//   panic_if(c, msg)  — panic when c is true
//
// Each prints `panic: <msg>  (<file>:<line>)` to stderr and calls
// `abort()` — so it's `noreturn` and the caller's control-flow analysis
// knows it. `format_panic` is the message-building half, split out so it can
// be tested without ending the process.

import cstdio  = core.stdc.stdio;
import cstdlib = core.stdc.stdlib;

// Build the panic line into `buf`, returning the filled slice (truncated to
// fit). No I/O, no abort — this is what the tests exercise.
const(char)[] format_panic(char[] buf, const(char)[] msg, const(char)[] file, int line) @nogc nothrow {
    if (buf.length == 0) return buf[0 .. 0];
    int n = cstdio.snprintf(buf.ptr, buf.length, "panic: %.*s  (%.*s:%d)",
        cast(int) msg.length, msg.ptr,
        cast(int) file.length, file.ptr,
        line);
    if (n < 0) return buf[0 .. 0];
    size_t len = cast(size_t) n < buf.length ? cast(size_t) n : buf.length - 1;
    return buf[0 .. len];
}

private noreturn fail(const(char)[] msg, const(char)[] file, int line) @nogc nothrow {
    char[512] buf = void;
    const(char)[] line_ = format_panic(buf[], msg, file, line);
    cstdio.fprintf(cstdio.stderr, "%.*s\n", cast(int) line_.length, line_.ptr);
    cstdlib.abort();
}

noreturn panic(const(char)[] msg, string file = __FILE__, int line = __LINE__) @nogc nothrow {
    fail(msg, file, line);
}

noreturn unreachable(const(char)[] msg = "entered unreachable code",
                     string file = __FILE__, int line = __LINE__) @nogc nothrow {
    fail(msg, file, line);
}

noreturn todo(const(char)[] msg = "not implemented",
              string file = __FILE__, int line = __LINE__) @nogc nothrow {
    fail(msg, file, line);
}

// Panic when `cond` is true. Returns normally otherwise, so it reads as a
// guard: `panic_if(n < 0, "negative count")`.
void panic_if(bool cond, const(char)[] msg, string file = __FILE__, int line = __LINE__) @nogc nothrow {
    if (cond) fail(msg, file, line);
}
