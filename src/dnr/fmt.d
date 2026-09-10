module dnr.fmt;

// ---------------------------------------------------------------------------
// fmt — typed, compile-time-checked string formatting
// ---------------------------------------------------------------------------
// The safe alternative to `snprintf`'s untyped varargs. The format string is a
// TEMPLATE argument (`format!"..."`), so it's parsed at compile time: a wrong
// placeholder count or a spec that doesn't fit the argument type is a build
// error, not a garbled string or a crash.
//
//   format!"lvl {} · {} kills · {}:{02}"(sb, level, kills, mins, secs);
//   auto line = format_buf!"{}/{}"(buf[], a, b);   // into a fixed stack buffer
//   eprintln!"unexpected tag {x}"(tag);            // to stderr + newline
//
// Placeholders:
//   {}      default — dispatched by the argument's type
//   {x} {X} hex (integers / pointers), lower / upper case
//   {.N}    a float with N fractional digits
//   {0N}    an integer zero-padded to width N
//   {{  }}  literal braces
//
// Default dispatch: bool -> true/false, char -> the char, integers ->
// signed/unsigned decimal, floats -> 6 digits, const(char)[] / string as-is,
// const(char)* via strlen, enum -> the member name, other pointers -> 0x….
//
// betterC: @nogc nothrow. Output goes through dnr.str's Sb, so a fixed-buffer
// Sb truncates and everything past the overflow no-ops.

import str = dnr.str;
import cstdio = core.stdc.stdio;

// A parsed format string: literal runs and argument slots. Fixed capacity —
// no `~` (betterC rejects it even in a CTFE-only function). A literal run is a
// slice of the format string, or the one-char string "{" / "}" for an escape.
private struct Piece {
    bool   isArg;
    string lit;       // when !isArg
    char   mode = 0;   // 0 | 'x' | 'X' | '.' | '0'
    int    num  = 0;   // precision / width for '.' and '0'
    int    argIdx = -1;
}

private enum MAX_PIECES = 64;

private struct Parsed {
    Piece[MAX_PIECES] pieces;
    size_t            count;
    int               args;
}

private void emit(ref Parsed r, Piece p) {
    assert(r.count < MAX_PIECES, "dnr.fmt: format string has too many pieces (raise MAX_PIECES)");
    r.pieces[r.count++] = p;
}

// CTFE only.
private Parsed parse_fmt(string f) {
    Parsed r;
    size_t i = 0;
    size_t litStart = 0;
    while (i < f.length) {
        immutable char c = f[i];
        if (c == '{') {
            if (i > litStart) emit(r, Piece(false, f[litStart .. i]));
            if (i + 1 < f.length && f[i + 1] == '{') {
                emit(r, Piece(false, "{"));
                i += 2; litStart = i; continue;
            }
            i++;
            char mode = 0;
            int num = 0;
            if (i < f.length && (f[i] == 'x' || f[i] == 'X')) {
                mode = f[i]; i++;
            } else if (i < f.length && (f[i] == '.' || f[i] == '0')) {
                mode = f[i]; i++;
                while (i < f.length && f[i] >= '0' && f[i] <= '9') { num = num * 10 + (f[i] - '0'); i++; }
            }
            assert(i < f.length && f[i] == '}', "dnr.fmt: unterminated or malformed { … }");
            i++;
            emit(r, Piece(true, null, mode, num, r.args++));
            litStart = i;
        } else if (c == '}') {
            assert(i + 1 < f.length && f[i + 1] == '}', "dnr.fmt: stray '}' — write '}}' for a literal brace");
            if (i > litStart) emit(r, Piece(false, f[litStart .. i]));
            emit(r, Piece(false, "}"));
            i += 2; litStart = i;
        } else {
            i++;
        }
    }
    if (i > litStart) emit(r, Piece(false, f[litStart .. i]));
    return r;
}

// Format into `sb`.
void format(string fmt, Args...)(ref str.Sb sb, Args args) @nogc nothrow {
    enum parsed = parse_fmt(fmt);
    static assert(parsed.args == Args.length,
        "dnr.fmt: format string placeholder count does not match the number of arguments");

    static foreach (pi; 0 .. parsed.count) {{
        enum p = parsed.pieces[pi];
        static if (!p.isArg)
            str.sb_put(sb, p.lit);
        else
            put_arg!(p.mode, p.num)(sb, args[p.argIdx]);
    }}
}

// Format into a caller buffer, returning the (possibly truncated) slice.
const(char)[] format_buf(string fmt, Args...)(char[] buf, Args args) @nogc nothrow {
    auto sb = str.sb_fixed(buf);
    format!(fmt, Args)(sb, args);
    return str.sb_slice(sb);
}

// Format + '\n' to stderr — a debug print. Truncates at 512 bytes.
void eprintln(string fmt, Args...)(Args args) @nogc nothrow {
    char[512] buf = void;
    auto sb = str.sb_fixed(buf[]);
    format!(fmt, Args)(sb, args);
    str.sb_put_char(sb, '\n');
    auto o = str.sb_slice(sb);
    cstdio.fprintf(cstdio.stderr, "%.*s", cast(int) o.length, o.ptr);
}

// --- per-argument dispatch --------------------------------------------

private void put_arg(char mode, int num, T)(ref str.Sb sb, T v) @nogc nothrow {
    static if (mode == 'x' || mode == 'X') {
        static assert(__traits(isIntegral, T) || is(T : const(void)*),
            "dnr.fmt: {x}/{X} needs an integer or pointer argument");
        str.sb_put_hex(sb, cast(ulong) v, num, mode == 'X');
    } else static if (mode == '.') {
        static assert(__traits(isFloating, T), "dnr.fmt: {.N} needs a floating-point argument");
        str.sb_put_float(sb, cast(double) v, num);
    } else static if (mode == '0') {
        static assert(__traits(isIntegral, T), "dnr.fmt: {0N} needs an integer argument");
        put_padded(sb, cast(long) v, num);
    } else {
        static if (is(T == bool))
            str.sb_put(sb, v ? "true" : "false");
        else static if (is(T == char))
            str.sb_put_char(sb, v);
        else static if (is(T == enum))
            put_enum(sb, v);
        else static if (__traits(isIntegral, T)) {
            static if (__traits(isUnsigned, T)) str.sb_put_uint(sb, cast(ulong) v);
            else str.sb_put_int(sb, cast(long) v);
        }
        else static if (__traits(isFloating, T))
            str.sb_put_float(sb, cast(double) v, 6);
        else static if (is(T : const(char)[]))
            str.sb_put(sb, v);
        else static if (is(T : const(char)*))
            str.sb_put(sb, str.from_cstr(v));
        else static if (is(T : const(void)*)) {
            str.sb_put(sb, "0x");
            str.sb_put_hex(sb, cast(ulong) v, 0);
        }
        else static assert(false, "dnr.fmt: no default formatter for type " ~ T.stringof);
    }
}

private void put_padded(ref str.Sb sb, long v, int width) @nogc nothrow {
    char[24] tmp = void;
    auto t = str.sb_fixed(tmp[]);
    str.sb_put_int(t, v);
    auto digits = str.sb_slice(t);
    // pad after a leading '-', so -5 width 4 -> "-005"
    size_t signLen = (digits.length && digits[0] == '-') ? 1 : 0;
    if (cast(int)(digits.length) < width) {
        if (signLen) str.sb_put_char(sb, '-');
        str.sb_put_rep(sb, '0', cast(size_t) width - digits.length);
        str.sb_put(sb, digits[signLen .. $]);
    } else {
        str.sb_put(sb, digits);
    }
}

private void put_enum(T)(ref str.Sb sb, T v) @nogc nothrow {
    static foreach (m; __traits(allMembers, T))
        if (v == __traits(getMember, T, m)) { str.sb_put(sb, m); return; }
    str.sb_put_int(sb, cast(long) v);   // an out-of-set value
}
