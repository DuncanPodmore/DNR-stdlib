module dnr.utf8;

// ---------------------------------------------------------------------------
// utf8 — minimal, strict UTF-8
// ---------------------------------------------------------------------------
// `dnr.str` is ASCII-only. This decodes / encodes code points and validates.
// Strict: overlong encodings, surrogate halves (U+D800..U+DFFF) and anything
// past U+10FFFF are errors, not silently accepted.
//
//   auto it = utf8_runes(text);
//   uint cp;
//   while (utf8_next(it).take(cp)) { ... }     // lossy — bad bytes -> U+FFFD
//
//   auto r = utf8_decode(text[i .. $]);        // strict — a Result
//   utf8_put(sb, cp);                          // append one code point to an Sb
//
// betterC: @nogc nothrow.

import str = dnr.str;
import res = dnr.result;

enum uint REPLACEMENT = 0xFFFD;
enum uint MAX_RUNE    = 0x10FFFF;

struct Rune {
    uint cp  = 0;
    ubyte len = 0;      // bytes this rune occupies (1..4)
}

// True length in bytes of `cp` encoded as UTF-8, or -1 if `cp` is not a valid
// scalar value.
int rune_len(uint cp) @nogc nothrow {
    if (cp < 0x80)   return 1;
    if (cp < 0x800)  return 2;
    if (cp >= 0xD800 && cp <= 0xDFFF) return -1;
    if (cp < 0x10000) return 3;
    if (cp <= MAX_RUNE) return 4;
    return -1;
}

// Decode the rune at the start of `s`. `StdErr.unexpected_eof` if `s` is empty
// or the sequence is truncated; `StdErr.invalid` for a bad lead byte, a bad
// continuation byte, an overlong encoding, a surrogate, or an out-of-range
// value.
res.Result!Rune utf8_decode(const(char)[] s) @nogc nothrow {
    if (s.length == 0) return res.err!Rune(res.StdErr.unexpected_eof);

    immutable uint b0 = cast(ubyte) s[0];
    if (b0 < 0x80) return res.ok(Rune(b0, 1));

    int n;
    uint cp;
    if ((b0 & 0xE0) == 0xC0)      { n = 2; cp = b0 & 0x1F; }
    else if ((b0 & 0xF0) == 0xE0) { n = 3; cp = b0 & 0x0F; }
    else if ((b0 & 0xF8) == 0xF0) { n = 4; cp = b0 & 0x07; }
    else return res.err!Rune(res.StdErr.invalid);   // 0x80..0xBF lead, or 0xF8+

    if (s.length < cast(size_t) n) return res.err!Rune(res.StdErr.unexpected_eof);
    foreach (k; 1 .. n) {
        immutable uint bk = cast(ubyte) s[k];
        if ((bk & 0xC0) != 0x80) return res.err!Rune(res.StdErr.invalid);
        cp = (cp << 6) | (bk & 0x3F);
    }

    static immutable uint[5] MIN_CP = [0, 0, 0x80, 0x800, 0x10000];
    if (cp < MIN_CP[n])                       return res.err!Rune(res.StdErr.invalid);  // overlong
    if (cp > MAX_RUNE)                        return res.err!Rune(res.StdErr.invalid);
    if (cp >= 0xD800 && cp <= 0xDFFF)         return res.err!Rune(res.StdErr.invalid);  // surrogate

    return res.ok(Rune(cp, cast(ubyte) n));
}

// Encode `cp` into `buf`, returning the byte count (1..4). `StdErr.invalid`
// for a surrogate or an out-of-range value.
res.Result!size_t utf8_encode(uint cp, ref char[4] buf) @nogc nothrow {
    if (cp < 0x80) {
        buf[0] = cast(char) cp;
        return res.ok!size_t(1);
    }
    if (cp < 0x800) {
        buf[0] = cast(char)(0xC0 | (cp >> 6));
        buf[1] = cast(char)(0x80 | (cp & 0x3F));
        return res.ok!size_t(2);
    }
    if (cp >= 0xD800 && cp <= 0xDFFF) return res.err!size_t(res.StdErr.invalid);
    if (cp < 0x10000) {
        buf[0] = cast(char)(0xE0 | (cp >> 12));
        buf[1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (cp & 0x3F));
        return res.ok!size_t(3);
    }
    if (cp > MAX_RUNE) return res.err!size_t(res.StdErr.invalid);
    buf[0] = cast(char)(0xF0 | (cp >> 18));
    buf[1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = cast(char)(0x80 | (cp & 0x3F));
    return res.ok!size_t(4);
}

// Append one code point to an Sb. false (and nothing written) if `cp` isn't a
// valid scalar value.
bool utf8_put(ref str.Sb sb, uint cp) @nogc nothrow {
    char[4] buf;
    size_t n;
    if (!utf8_encode(cp, buf).take(n)) return false;
    str.sb_put(sb, buf[0 .. n]);
    return true;
}

// Is the whole slice well-formed UTF-8?
bool utf8_validate(const(char)[] s) @nogc nothrow {
    size_t i = 0;
    while (i < s.length) {
        Rune r;
        if (!utf8_decode(s[i .. $]).take(r)) return false;
        i += r.len;
    }
    return true;
}

// Number of code points, or `StdErr.invalid` on the first malformed sequence.
res.Result!size_t utf8_count(const(char)[] s) @nogc nothrow {
    size_t i = 0, n = 0;
    while (i < s.length) {
        Rune r;
        if (!utf8_decode(s[i .. $]).take(r)) return res.err!size_t(res.StdErr.invalid);
        i += r.len;
        n++;
    }
    return res.ok(n);
}

// --- iterator ---------------------------------------------------------
// Lossy: a malformed byte yields U+FFFD and advances one byte, so a bad
// stream never stalls the loop. Use `utf8_decode` directly when you need to
// know about the error.

struct RuneReader {
    const(char)[] rest;
}

RuneReader utf8_runes(const(char)[] s) @nogc nothrow {
    return RuneReader(s);
}
RuneReader utf8_runes(const(ubyte)[] s) @nogc nothrow {
    return RuneReader(cast(const(char)[]) s);
}

res.Option!uint utf8_next(ref RuneReader r) @nogc nothrow {
    if (r.rest.length == 0) return res.none!uint();
    Rune ru;
    if (!utf8_decode(r.rest).take(ru)) {
        r.rest = r.rest[1 .. $];
        return res.some!uint(REPLACEMENT);
    }
    r.rest = r.rest[ru.len .. $];
    return res.some!uint(ru.cp);
}
