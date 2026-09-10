module dnr.str;

// ---------------------------------------------------------------------------
// str — string handling for betterC
// ---------------------------------------------------------------------------
// betterC drops std.string, std.conv and std.format along with the runtime.
// This module is the replacement, in three parts:
//
//   1. slice ops on `const(char)[]` — views, no allocation (equals /
//      starts_with / trim / find / the Splitter iterator / ASCII classify)
//   2. parsing — text to number (parse_int / parse_uint / parse_hex /
//      parse_float), each `-> bool` with the value in an out-parameter
//   3. Sb — a StringBuilder over an Allocator, for formatting
//
// A "string" here is `const(char)[]`: a slice, NOT null-terminated. Use
// `from_cstr` at the C boundary and `Sb.cstr` to go back. ASCII only — the
// classify/case helpers do not know Unicode.
//
// betterC: @nogc nothrow throughout.

import mem = dnr.mem;
import cstr = core.stdc.string;
import cstdio = core.stdc.stdio;
import cstdlib = core.stdc.stdlib;

// ===========================================================================
// 1. slice operations
// ===========================================================================

const(char)[] from_cstr(const(char)* p) @nogc nothrow {
    return p is null ? null : p[0 .. cstr.strlen(p)];
}

bool equals(const(char)[] a, const(char)[] b) @nogc nothrow {
    if (a.length != b.length) return false;
    return a.length == 0 || cstr.memcmp(a.ptr, b.ptr, a.length) == 0;
}

bool equals_ci(const(char)[] a, const(char)[] b) @nogc nothrow {
    if (a.length != b.length) return false;
    foreach (i, c; a) if (to_lower(c) != to_lower(b[i])) return false;
    return true;
}

bool starts_with(const(char)[] s, const(char)[] prefix) @nogc nothrow {
    return s.length >= prefix.length && equals(s[0 .. prefix.length], prefix);
}

bool ends_with(const(char)[] s, const(char)[] suffix) @nogc nothrow {
    return s.length >= suffix.length && equals(s[$ - suffix.length .. $], suffix);
}

// Byte index of the first `c`, or -1.
ptrdiff_t index_of(const(char)[] s, char c) @nogc nothrow {
    foreach (i, ch; s) if (ch == c) return cast(ptrdiff_t) i;
    return -1;
}

// Byte index of the first occurrence of `sub`, or -1. Empty `sub` -> 0.
ptrdiff_t index_of(const(char)[] s, const(char)[] sub) @nogc nothrow {
    if (sub.length == 0) return 0;
    if (sub.length > s.length) return -1;
    foreach (i; 0 .. s.length - sub.length + 1)
        if (cstr.memcmp(s.ptr + i, sub.ptr, sub.length) == 0) return cast(ptrdiff_t) i;
    return -1;
}

ptrdiff_t last_index_of(const(char)[] s, char c) @nogc nothrow {
    foreach_reverse (i, ch; s) if (ch == c) return cast(ptrdiff_t) i;
    return -1;
}

bool contains(const(char)[] s, const(char)[] sub) @nogc nothrow { return index_of(s, sub) >= 0; }
bool contains(const(char)[] s, char c) @nogc nothrow { return index_of(s, c) >= 0; }

size_t count_char(const(char)[] s, char c) @nogc nothrow {
    size_t n = 0;
    foreach (ch; s) if (ch == c) n++;
    return n;
}

const(char)[] trim_left(const(char)[] s) @nogc nothrow {
    size_t i = 0;
    while (i < s.length && is_space(s[i])) i++;
    return s[i .. $];
}
const(char)[] trim_right(const(char)[] s) @nogc nothrow {
    size_t n = s.length;
    while (n > 0 && is_space(s[n - 1])) n--;
    return s[0 .. n];
}
const(char)[] trim(const(char)[] s) @nogc nothrow { return trim_right(trim_left(s)); }

// If `s` begins with `prefix`, return the rest; otherwise return `s` unchanged.
const(char)[] strip_prefix(const(char)[] s, const(char)[] prefix) @nogc nothrow {
    return starts_with(s, prefix) ? s[prefix.length .. $] : s;
}
const(char)[] strip_suffix(const(char)[] s, const(char)[] suffix) @nogc nothrow {
    return ends_with(s, suffix) ? s[0 .. $ - suffix.length] : s;
}

// --- the Splitter iterator ----------------------------------------------
// Standard split semantics: "a,b" -> "a","b"; "a," -> "a",""; "" -> "".
// Idiom:
//   auto it = split(line, ',');
//   const(char)[] field;
//   while (next(it, field)) { ... }

struct Splitter {
    const(char)[] rest;
    char sep = 0;
    bool ws = false;    // split on runs of whitespace instead of a single char
    bool done = false;
}

Splitter split(const(char)[] s, char sep) @nogc nothrow {
    return Splitter(s, sep, false, false);
}

// Split on runs of whitespace, skipping leading/trailing — i.e. tokenize.
// "  a   b " yields "a","b" and nothing empty.
Splitter split_ws(const(char)[] s) @nogc nothrow {
    return Splitter(trim_left(s), 0, true, false);
}

bool next(ref Splitter it, ref const(char)[] field) @nogc nothrow {
    if (it.done) return false;

    if (it.ws) {
        if (it.rest.length == 0) { it.done = true; return false; }
        size_t i = 0;
        while (i < it.rest.length && !is_space(it.rest[i])) i++;
        field = it.rest[0 .. i];
        size_t j = i;
        while (j < it.rest.length && is_space(it.rest[j])) j++;
        it.rest = it.rest[j .. $];
        if (it.rest.length == 0) it.done = true;
        return true;
    }

    ptrdiff_t at = index_of(it.rest, it.sep);
    if (at < 0) {
        field = it.rest;
        it.rest = it.rest[$ .. $];
        it.done = true;
        return true;
    }
    field = it.rest[0 .. at];
    it.rest = it.rest[at + 1 .. $];
    return true;
}

// --- ASCII classify / case --------------------------------------------

bool is_space(char c) @nogc nothrow {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}
bool is_digit(char c) @nogc nothrow { return c >= '0' && c <= '9'; }
bool is_hex_digit(char c) @nogc nothrow {
    return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
bool is_upper(char c) @nogc nothrow { return c >= 'A' && c <= 'Z'; }
bool is_lower(char c) @nogc nothrow { return c >= 'a' && c <= 'z'; }
bool is_alpha(char c) @nogc nothrow { return is_upper(c) || is_lower(c); }
bool is_alnum(char c) @nogc nothrow { return is_alpha(c) || is_digit(c); }

char to_lower(char c) @nogc nothrow { return is_upper(c) ? cast(char)(c + 32) : c; }
char to_upper(char c) @nogc nothrow { return is_lower(c) ? cast(char)(c - 32) : c; }

// ===========================================================================
// 2. parsing
// ===========================================================================
// Each returns false and leaves the out-parameter untouched on any malformed
// input. The whole slice must be consumed — leading/trailing spaces included
// would fail; `trim` first if that is not what you want.

// Signed base-10. Accepts an optional leading '+' / '-'. Overflow -> false.
bool parse_int(const(char)[] s, ref long out_) @nogc nothrow {
    if (s.length == 0) return false;
    bool neg = false;
    size_t i = 0;
    if (s[0] == '+' || s[0] == '-') { neg = s[0] == '-'; i = 1; }
    if (i == s.length) return false;

    ulong acc = 0;
    for (; i < s.length; i++) {
        if (!is_digit(s[i])) return false;
        ulong d = cast(ulong)(s[i] - '0');
        // guard against ulong overflow, then against long range
        if (acc > (ulong.max - d) / 10) return false;
        acc = acc * 10 + d;
    }
    if (neg) {
        if (acc > cast(ulong) long.max + 1) return false;
        out_ = -cast(long) acc;
    } else {
        if (acc > cast(ulong) long.max) return false;
        out_ = cast(long) acc;
    }
    return true;
}

// Unsigned base-10. A leading '+' is allowed, '-' is not.
bool parse_uint(const(char)[] s, ref ulong out_) @nogc nothrow {
    if (s.length == 0) return false;
    size_t i = (s[0] == '+') ? 1 : 0;
    if (i == s.length) return false;
    ulong acc = 0;
    for (; i < s.length; i++) {
        if (!is_digit(s[i])) return false;
        ulong d = cast(ulong)(s[i] - '0');
        if (acc > (ulong.max - d) / 10) return false;
        acc = acc * 10 + d;
    }
    out_ = acc;
    return true;
}

// Base-16, optional "0x" / "0X" prefix, case-insensitive. Overflow -> false.
bool parse_hex(const(char)[] s, ref ulong out_) @nogc nothrow {
    if (s.length == 0) return false;
    if (s.length >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s = s[2 .. $];
    if (s.length == 0) return false;
    ulong acc = 0;
    foreach (c; s) {
        if (!is_hex_digit(c)) return false;
        uint d = is_digit(c) ? cast(uint)(c - '0')
               : cast(uint)(to_lower(c) - 'a' + 10);
        if (acc > (ulong.max >> 4)) return false;
        acc = (acc << 4) | d;
    }
    out_ = acc;
    return true;
}

// Base-10 float, via the C library for correct rounding. The slice is copied
// into a stack buffer (so a very long literal — over 127 chars — is rejected)
// and `strtod` must consume all of it.
bool parse_float(const(char)[] s, ref double out_) @nogc nothrow {
    if (s.length == 0 || s.length > 127) return false;
    if (is_space(s[0])) return false;   // strtod would skip it; we want strict
    char[128] buf = void;
    cstr.memcpy(buf.ptr, s.ptr, s.length);
    buf[s.length] = 0;
    char* end;
    double v = cstdlib.strtod(buf.ptr, &end);
    if (end != buf.ptr + s.length) return false;   // trailing junk, or nothing parsed
    out_ = v;
    return true;
}

// ===========================================================================
// 3. Sb — a StringBuilder over an Allocator
// ===========================================================================
// Grows a single buffer. Every `put_*` is chainable and no-ops once an
// allocation has failed — check `sb.ok` (or the return of `sb_reserve`) once
// at the end rather than after each call. `sb_slice` is the contents;
// `sb_cstr` appends a '\0' (not counted) and returns a C pointer.

struct Sb {
    char[]        buf;    // buf[0 .. len] is live
    size_t        len;
    mem.Allocator a;
    bool          ok = true;
}

Sb sb_make(mem.Allocator a, size_t reserve = 0) @nogc nothrow {
    Sb s;
    s.a = a;
    if (reserve) sb_reserve(s, reserve);
    return s;
}

void sb_free(ref Sb s) @nogc nothrow {
    if (s.buf.length) s.a.raw_free(s.buf.ptr, s.buf.length);
    s.buf = null;
    s.len = 0;
    s.ok = true;
}

// Length back to 0, buffer kept.
void sb_reset(ref Sb s) @nogc nothrow { s.len = 0; s.ok = true; }

const(char)[] sb_slice(ref Sb s) @nogc nothrow { return s.buf[0 .. s.len]; }
size_t sb_len(ref Sb s) @nogc nothrow { return s.len; }

bool sb_reserve(ref Sb s, size_t want) @nogc nothrow {
    if (!s.ok) return false;
    if (want <= s.buf.length) return true;
    size_t cap = s.buf.length < 16 ? 16 : s.buf.length;
    while (cap < want) cap *= 2;
    void* p = s.buf.length
        ? s.a.raw_realloc(s.buf.ptr, s.buf.length, cap, 1)
        : s.a.raw_alloc(cap, 1);
    if (p is null) { s.ok = false; return false; }
    s.buf = (cast(char*) p)[0 .. cap];
    return true;
}

void sb_put(ref Sb s, const(char)[] str) @nogc nothrow {
    if (!s.ok || str.length == 0) return;
    if (!sb_reserve(s, s.len + str.length)) return;
    cstr.memcpy(s.buf.ptr + s.len, str.ptr, str.length);
    s.len += str.length;
}

void sb_put_char(ref Sb s, char c) @nogc nothrow {
    if (!s.ok) return;
    if (!sb_reserve(s, s.len + 1)) return;
    s.buf[s.len++] = c;
}

// c repeated n times.
void sb_put_rep(ref Sb s, char c, size_t n) @nogc nothrow {
    if (!s.ok || n == 0) return;
    if (!sb_reserve(s, s.len + n)) return;
    cstr.memset(s.buf.ptr + s.len, c, n);
    s.len += n;
}

void sb_put_int(ref Sb s, long v) @nogc nothrow {
    if (!s.ok) return;
    char[24] tmp = void;
    size_t n = 0;
    bool neg = v < 0;
    ulong u = neg ? -cast(ulong) v : cast(ulong) v;
    do { tmp[n++] = cast(char)('0' + u % 10); u /= 10; } while (u);
    if (neg) tmp[n++] = '-';
    // digits are reversed in tmp
    if (!sb_reserve(s, s.len + n)) return;
    foreach_reverse (k; 0 .. n) s.buf[s.len++] = tmp[k];
}

void sb_put_uint(ref Sb s, ulong u) @nogc nothrow {
    if (!s.ok) return;
    char[24] tmp = void;
    size_t n = 0;
    do { tmp[n++] = cast(char)('0' + u % 10); u /= 10; } while (u);
    if (!sb_reserve(s, s.len + n)) return;
    foreach_reverse (k; 0 .. n) s.buf[s.len++] = tmp[k];
}

// Lower-case hex, no "0x". `min_digits` left-pads with '0'.
void sb_put_hex(ref Sb s, ulong u, int min_digits = 0) @nogc nothrow {
    if (!s.ok) return;
    static immutable char[16] D = "0123456789abcdef";
    char[16] tmp = void;
    size_t n = 0;
    do { tmp[n++] = D[u & 0xF]; u >>= 4; } while (u);
    while (cast(int) n < min_digits) tmp[n++] = '0';
    if (!sb_reserve(s, s.len + n)) return;
    foreach_reverse (k; 0 .. n) s.buf[s.len++] = tmp[k];
}

// Fixed-notation, `prec` digits after the point — via snprintf for correct
// rounding.
void sb_put_float(ref Sb s, double v, int prec = 6) @nogc nothrow {
    if (!s.ok) return;
    char[64] tmp = void;
    int n = cstdio.snprintf(tmp.ptr, tmp.length, "%.*f", prec, v);
    if (n > 0) sb_put(s, tmp[0 .. n < cast(int) tmp.length ? n : cast(int) tmp.length]);
}

// Append a '\0' without counting it, and return a C string pointer valid
// until the next mutation of `s`.
const(char)* sb_cstr(ref Sb s) @nogc nothrow {
    if (!s.ok) return "".ptr;
    if (!sb_reserve(s, s.len + 1)) return "".ptr;
    s.buf[s.len] = 0;
    return s.buf.ptr;
}
