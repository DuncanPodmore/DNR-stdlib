module dnr.io;

// ---------------------------------------------------------------------------
// io — whole-file read/write and line iteration
// ---------------------------------------------------------------------------
// Thin wrappers over `core.stdc.stdio`. The common jobs: pull a config or
// data file into memory, walk it line by line, write one back. Not a
// streaming layer — `FILE*` is already buffered by libc, and formatting goes
// through `dnr.str`'s `Sb` then one `write_file`.
//
// Paths are `const(char)[]` (copied into a stack buffer to null-terminate, so
// a path over 1023 bytes is rejected). Read buffers come from the `Allocator`
// you pass; free them with `dnr.mem.free_n`. Regular files only — the size is
// taken with `fseek`/`ftell`.
//
// betterC: @nogc nothrow. Failure is an empty slice / `false`, never a throw.

import mem = dnr.mem;
import str = dnr.str;
import c = core.stdc.stdio;
import cstr = core.stdc.string;

private enum PATH_MAX = 1024;

// Copy a slice path into `buf` as a C string. false if it doesn't fit.
private bool to_cpath(const(char)[] path, ref char[PATH_MAX] buf) @nogc nothrow {
    if (path.length >= PATH_MAX) return false;
    cstr.memcpy(buf.ptr, path.ptr, path.length);
    buf[path.length] = 0;
    return true;
}

bool file_exists(const(char)[] path) @nogc nothrow {
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return false;
    c.FILE* f = c.fopen(cp.ptr, "rb");
    if (f is null) return false;
    c.fclose(f);
    return true;
}

// File size in bytes, or -1 on error / non-seekable.
long file_size(const(char)[] path) @nogc nothrow {
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return -1;
    c.FILE* f = c.fopen(cp.ptr, "rb");
    if (f is null) return -1;
    long n = -1;
    if (c.fseek(f, 0, c.SEEK_END) == 0) {
        long t = c.ftell(f);
        if (t >= 0) n = t;
    }
    c.fclose(f);
    return n;
}

// Read the whole file into a fresh buffer from `a`. Empty slice on any
// failure (missing / unreadable / non-seekable / OOM). An empty *file*
// succeeds and also returns an empty slice — call `file_exists` first if the
// difference matters. Free with `mem.free_n(a, buf)`.
ubyte[] read_file(mem.Allocator a, const(char)[] path) @nogc nothrow {
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return null;

    c.FILE* f = c.fopen(cp.ptr, "rb");
    if (f is null) return null;
    scope (exit) c.fclose(f);

    if (c.fseek(f, 0, c.SEEK_END) != 0) return null;
    long end = c.ftell(f);
    if (end < 0) return null;
    if (c.fseek(f, 0, c.SEEK_SET) != 0) return null;
    if (end == 0) return null;

    ubyte[] buf = mem.make_n!ubyte(a, cast(size_t) end);
    if (buf is null) return null;

    size_t got = c.fread(buf.ptr, 1, buf.length, f);
    if (got != buf.length) {
        mem.free_n(a, buf);
        return null;
    }
    return buf;
}

// Same, typed as text. (Bytes are not validated as UTF-8 — it's still just
// the file's contents.)
char[] read_file_text(mem.Allocator a, const(char)[] path) @nogc nothrow {
    ubyte[] b = read_file(a, path);
    return cast(char[]) b;
}

// Write `data` to `path`, replacing it. Creates the file; does not create
// missing parent directories. true on success.
bool write_file(const(char)[] path, const(void)[] data) @nogc nothrow {
    return write_mode(path, data, "wb");
}

// Append `data` to `path` (creating it if absent).
bool append_file(const(char)[] path, const(void)[] data) @nogc nothrow {
    return write_mode(path, data, "ab");
}

private bool write_mode(const(char)[] path, const(void)[] data, const(char)* mode) @nogc nothrow {
    char[PATH_MAX] cp = void;
    if (!to_cpath(path, cp)) return false;
    c.FILE* f = c.fopen(cp.ptr, mode);
    if (f is null) return false;
    bool ok = true;
    if (data.length) ok = c.fwrite(data.ptr, 1, data.length, f) == data.length;
    if (c.fclose(f) != 0) ok = false;
    return ok;
}

// --- line iteration over an in-memory buffer --------------------------
// Splits on '\n', drops a single trailing '\r' from each line (so CRLF files
// work), and does NOT yield a spurious empty line when the buffer ends with a
// newline. An empty buffer yields nothing.
//   auto it = lines(buf);
//   const(char)[] ln;
//   while (next_line(it, ln)) { ... }

struct LineReader {
    const(char)[] rest;
}

LineReader lines(const(char)[] buf) @nogc nothrow {
    return LineReader(buf);
}
LineReader lines(const(ubyte)[] buf) @nogc nothrow {
    return LineReader(cast(const(char)[]) buf);
}

bool next_line(ref LineReader it, ref const(char)[] line) @nogc nothrow {
    if (it.rest.length == 0) return false;
    ptrdiff_t nl = str.index_of(it.rest, '\n');
    if (nl < 0) {
        line = it.rest;
        it.rest = it.rest[$ .. $];
    } else {
        line = it.rest[0 .. nl];
        it.rest = it.rest[nl + 1 .. $];
    }
    if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
    return true;
}
