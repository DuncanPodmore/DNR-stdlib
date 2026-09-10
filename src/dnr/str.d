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
//      parse_float), each returning `Result!T`
//   3. Sb — a StringBuilder over an Allocator, for formatting
//
// A "string" here is `const(char)[]`: a slice, NOT null-terminated. Use
// `from_cstr` at the C boundary and `Sb.cstr` to go back. ASCII only — the
// classify/case helpers do not know Unicode.
//
// betterC: @nogc nothrow throughout.

import mem = dnr.mem;
import res = dnr.result;
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

// Byte index of the first `c`, or `none`.
res.Option!size_t index_of(const(char)[] s, char c) @nogc nothrow {
    foreach (i, ch; s) if (ch == c) return res.some(i);
    return res.none!size_t();
}

// Byte index of the first occurrence of `sub`, or `none`. Empty `sub` -> 0.
res.Option!size_t index_of(const(char)[] s, const(char)[] sub) @nogc nothrow {
    if (sub.length == 0) return res.some!size_t(0);
    if (sub.length > s.length) return res.none!size_t();
    foreach (i; 0 .. s.length - sub.length + 1)
        if (cstr.memcmp(s.ptr + i, sub.ptr, sub.length) == 0) return res.some(i);
    return res.none!size_t();
}

res.Option!size_t last_index_of(const(char)[] s, char c) @nogc nothrow {
    foreach_reverse (i, ch; s) if (ch == c) return res.some(i);
    return res.none!size_t();
}

bool contains(const(char)[] s, const(char)[] sub) @nogc nothrow { return index_of(s, sub).is_some(); }
bool contains(const(char)[] s, char c) @nogc nothrow { return index_of(s, c).is_some(); }

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
//   while (split_next(it).take(field)) { ... }

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

// The next field, or `none` when the iterator is spent.
res.Option!(const(char)[]) split_next(ref Splitter it) @nogc nothrow {
    if (it.done) return res.none!(const(char)[])();

    if (it.ws) {
        if (it.rest.length == 0) { it.done = true; return res.none!(const(char)[])(); }
        size_t i = 0;
        while (i < it.rest.length && !is_space(it.rest[i])) i++;
        const(char)[] field = it.rest[0 .. i];
        size_t j = i;
        while (j < it.rest.length && is_space(it.rest[j])) j++;
        it.rest = it.rest[j .. $];
        if (it.rest.length == 0) it.done = true;
        return res.some(field);
    }

    auto at = index_of(it.rest, it.sep);
    size_t pos;
    if (!at.take(pos)) {
        const(char)[] field = it.rest;
        it.rest = it.rest[$ .. $];
        it.done = true;
        return res.some(field);
    }
    const(char)[] field = it.rest[0 .. pos];
    it.rest = it.rest[pos + 1 .. $];
    return res.some(field);
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
// Each returns `Result!T` — `StdErr.invalid` for malformed input,
// `StdErr.overflow` when the value doesn't fit. The whole slice must be
// valid: leading/trailing spaces fail, so `trim` first if that's not wanted.

// Signed base-10. Accepts an optional leading '+' / '-'.
res.Result!long parse_int(const(char)[] s) @nogc nothrow {
    if (s.length == 0) return res.err!long(res.StdErr.invalid);
    bool neg = false;
    size_t i = 0;
    if (s[0] == '+' || s[0] == '-') { neg = s[0] == '-'; i = 1; }
    if (i == s.length) return res.err!long(res.StdErr.invalid);

    ulong acc = 0;
    for (; i < s.length; i++) {
        if (!is_digit(s[i])) return res.err!long(res.StdErr.invalid);
        ulong d = cast(ulong)(s[i] - '0');
        if (acc > (ulong.max - d) / 10) return res.err!long(res.StdErr.overflow);
        acc = acc * 10 + d;
    }
    if (neg) {
        if (acc > cast(ulong) long.max + 1) return res.err!long(res.StdErr.overflow);
        return res.ok(-cast(long) acc);
    }
    if (acc > cast(ulong) long.max) return res.err!long(res.StdErr.overflow);
    return res.ok(cast(long) acc);
}

// Unsigned base-10. A leading '+' is allowed, '-' is not.
res.Result!ulong parse_uint(const(char)[] s) @nogc nothrow {
    if (s.length == 0) return res.err!ulong(res.StdErr.invalid);
    size_t i = (s[0] == '+') ? 1 : 0;
    if (i == s.length) return res.err!ulong(res.StdErr.invalid);
    ulong acc = 0;
    for (; i < s.length; i++) {
        if (!is_digit(s[i])) return res.err!ulong(res.StdErr.invalid);
        ulong d = cast(ulong)(s[i] - '0');
        if (acc > (ulong.max - d) / 10) return res.err!ulong(res.StdErr.overflow);
        acc = acc * 10 + d;
    }
    return res.ok(acc);
}

// Base-16, optional "0x" / "0X" prefix, case-insensitive.
res.Result!ulong parse_hex(const(char)[] s) @nogc nothrow {
    if (s.length == 0) return res.err!ulong(res.StdErr.invalid);
    if (s.length >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s = s[2 .. $];
    if (s.length == 0) return res.err!ulong(res.StdErr.invalid);
    ulong acc = 0;
    foreach (c; s) {
        if (!is_hex_digit(c)) return res.err!ulong(res.StdErr.invalid);
        uint d = is_digit(c) ? cast(uint)(c - '0')
               : cast(uint)(to_lower(c) - 'a' + 10);
        if (acc > (ulong.max >> 4)) return res.err!ulong(res.StdErr.overflow);
        acc = (acc << 4) | d;
    }
    return res.ok(acc);
}

// Base-10 float, via the C library for correct rounding. The slice is copied
// into a stack buffer (so a very long literal — over 127 chars — is rejected)
// and `strtod` must consume all of it.
res.Result!double parse_float(const(char)[] s) @nogc nothrow {
    if (s.length == 0 || s.length > 127) return res.err!double(res.StdErr.invalid);
    if (is_space(s[0])) return res.err!double(res.StdErr.invalid);  // strtod would skip it
    char[128] buf = void;
    cstr.memcpy(buf.ptr, s.ptr, s.length);
    buf[s.length] = 0;
    char* end;
    double v = cstdlib.strtod(buf.ptr, &end);
    if (end != buf.ptr + s.length) return res.err!double(res.StdErr.invalid);
    return res.ok(v);
}

// ===========================================================================
// 3. Sb — a StringBuilder over an Allocator
// ===========================================================================
// Grows a single buffer. Every `put_*` is chainable and no-ops once an
// allocation has failed (or a fixed buffer filled up) — check `sb.ok` (or the
// return of `sb_reserve`) once at the end rather than after each call.
// `sb_slice` is the contents; `sb_cstr` appends a '\0' (not counted).
//
// `sb_fixed` wraps a caller-provided `char[]` with no allocator: it can't
// grow, so overflowing it truncates and latches `ok` false.

struct Sb {
    char[]        buf;    // buf[0 .. len] is live
    size_t        len;
    mem.Allocator a;
    bool          ok = true;
    bool          fixed = false;   // buf is caller-owned, cannot grow
}

Sb sb_make(mem.Allocator a, size_t reserve = 0) @nogc nothrow {
    Sb s;
    s.a = a;
    if (reserve) cast(void) sb_reserve(s, reserve);
    return s;
}

// A builder over a fixed caller buffer — no allocation. Overflow truncates
// and sets `ok` false.
Sb sb_fixed(char[] buf) @nogc nothrow {
    Sb s;
    s.buf = buf;
    s.fixed = true;
    return s;
}

void sb_free(ref Sb s) @nogc nothrow {
    if (!s.fixed && s.buf.length) s.a.raw_free(s.buf.ptr, s.buf.length);
    s.buf = null;
    s.len = 0;
    s.ok = true;
}

// Length back to 0, buffer kept.
void sb_reset(ref Sb s) @nogc nothrow { s.len = 0; s.ok = true; }

const(char)[] sb_slice(ref Sb s) @nogc nothrow { return s.buf[0 .. s.len]; }
size_t sb_len(ref Sb s) @nogc nothrow { return s.len; }

// `pass()`, or `StdErr.oom` (which also latches `s.ok` false so later put_*
// calls no-op). Once you've built the string, `s.ok` is the single check.
res.Status sb_reserve(ref Sb s, size_t want) @nogc nothrow {
    if (!s.ok) return res.fail(res.StdErr.oom);
    if (want <= s.buf.length) return res.pass();
    if (s.fixed) { s.ok = false; return res.fail(res.StdErr.oom); }
    size_t cap = s.buf.length < 16 ? 16 : s.buf.length;
    while (cap < want) cap *= 2;
    void* p = s.buf.length
        ? s.a.raw_realloc(s.buf.ptr, s.buf.length, cap, 1)
        : s.a.raw_alloc(cap, 1);
    if (p is null) { s.ok = false; return res.fail(res.StdErr.oom); }
    s.buf = (cast(char*) p)[0 .. cap];
    return res.pass();
}

void sb_put(ref Sb s, const(char)[] str) @nogc nothrow {
    if (!s.ok || str.length == 0) return;
    if (sb_reserve(s, s.len + str.length).is_err) {
        // fixed buffer overflowed — copy what fits, byte-truncated like snprintf
        size_t room = s.len < s.buf.length ? s.buf.length - s.len : 0;
        if (room) { cstr.memcpy(s.buf.ptr + s.len, str.ptr, room); s.len += room; }
        return;
    }
    cstr.memcpy(s.buf.ptr + s.len, str.ptr, str.length);
    s.len += str.length;
}

void sb_put_char(ref Sb s, char c) @nogc nothrow {
    if (!s.ok) return;
    if (sb_reserve(s, s.len + 1).is_err) return;
    s.buf[s.len++] = c;
}

// c repeated n times.
void sb_put_rep(ref Sb s, char c, size_t n) @nogc nothrow {
    if (!s.ok || n == 0) return;
    if (sb_reserve(s, s.len + n).is_err) return;
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
    if (sb_reserve(s, s.len + n).is_err) return;
    foreach_reverse (k; 0 .. n) s.buf[s.len++] = tmp[k];
}

void sb_put_uint(ref Sb s, ulong u) @nogc nothrow {
    if (!s.ok) return;
    char[24] tmp = void;
    size_t n = 0;
    do { tmp[n++] = cast(char)('0' + u % 10); u /= 10; } while (u);
    if (sb_reserve(s, s.len + n).is_err) return;
    foreach_reverse (k; 0 .. n) s.buf[s.len++] = tmp[k];
}

// Hex, no "0x". `min_digits` left-pads with '0'; `upper` for A-F.
void sb_put_hex(ref Sb s, ulong u, int min_digits = 0, bool upper = false) @nogc nothrow {
    if (!s.ok) return;
    static immutable char[16] LO = "0123456789abcdef";
    static immutable char[16] HI = "0123456789ABCDEF";
    const(char)[16] D = upper ? HI : LO;
    char[16] tmp = void;
    size_t n = 0;
    do { tmp[n++] = D[u & 0xF]; u >>= 4; } while (u);
    while (cast(int) n < min_digits) tmp[n++] = '0';
    if (sb_reserve(s, s.len + n).is_err) return;
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
    if (sb_reserve(s, s.len + 1).is_err) return "".ptr;
    s.buf[s.len] = 0;
    return s.buf.ptr;
}
