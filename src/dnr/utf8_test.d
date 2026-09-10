module dnr.utf8_test;

import dnr.testing;
import dnr.mem;
import s = dnr.str;
import u = dnr.utf8;

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

void test_rune_len() {
    check(u.rune_len('A') == 1, "ASCII is 1 byte");
    check(u.rune_len('é') == 2, "U+00E9 é is 2 bytes");
    check(u.rune_len('€') == 3, "U+20AC € is 3 bytes");
    check(u.rune_len('\U0001F600') == 4, "U+1F600 😀 is 4 bytes");
    check(u.rune_len(0xD800) == -1, "a surrogate has no length");
    check(u.rune_len(0x110000) == -1, "past U+10FFFF has no length");
}

void test_decode_valid() {
    u.Rune r;

    check(u.utf8_decode("A").take(r) && r.cp == 'A' && r.len == 1, "decode ASCII");

    // "é€😀" as bytes
    immutable string mix = "é€\U0001F600";
    check(u.utf8_decode(mix).take(r) && r.cp == 0x00E9 && r.len == 2, "decode 2-byte");
    check(u.utf8_decode(mix[2 .. $]).take(r) && r.cp == 0x20AC && r.len == 3, "decode 3-byte");
    check(u.utf8_decode(mix[5 .. $]).take(r) && r.cp == 0x1F600 && r.len == 4, "decode 4-byte");
}

void test_decode_errors() {
    check(u.utf8_decode("").is_err(), "empty input");

    immutable char[1] loneCont = [cast(char) 0x80];
    check(u.utf8_decode(loneCont[]).is_err(), "a lone continuation byte");

    immutable char[1] truncated = [cast(char) 0xE2];   // start of a 3-byte seq
    check(u.utf8_decode(truncated[]).is_err(), "a truncated sequence");

    immutable char[2] badCont = [cast(char) 0xC3, cast(char) 0x28];  // 'Ã' then '('
    check(u.utf8_decode(badCont[]).is_err(), "a bad continuation byte");

    immutable char[2] overlong = [cast(char) 0xC0, cast(char) 0x80]; // overlong NUL
    check(u.utf8_decode(overlong[]).is_err(), "an overlong encoding");

    immutable char[3] surrogate = [cast(char) 0xED, cast(char) 0xA0, cast(char) 0x80]; // U+D800
    check(u.utf8_decode(surrogate[]).is_err(), "an encoded surrogate");

    immutable char[4] tooBig = [cast(char) 0xF4, cast(char) 0x90, cast(char) 0x80, cast(char) 0x80]; // U+110000
    check(u.utf8_decode(tooBig[]).is_err(), "past U+10FFFF");
}

void test_encode_roundtrip() {
    uint[6] cps = ['A', 0x00E9, 0x20AC, 0x1F600, 0x7F, 0x10FFFF];
    bool ok = true;
    foreach (cp; cps) {
        char[4] buf;
        size_t n;
        if (!u.utf8_encode(cp, buf).take(n)) { ok = false; continue; }
        if (cast(int) n != u.rune_len(cp)) ok = false;
        u.Rune r;
        if (!u.utf8_decode(buf[0 .. n]).take(r) || r.cp != cp || r.len != n) ok = false;
    }
    check(ok, "encode then decode round-trips every code point");

    char[4] b;
    check(u.utf8_encode(0xDC00, b).is_err(), "encode rejects a surrogate");
    check(u.utf8_encode(0x200000, b).is_err(), "encode rejects an out-of-range value");
}

void test_validate_and_count() {
    check(u.utf8_validate("plain ascii"), "ascii validates");
    check(u.utf8_validate("é€\U0001F600 tail"), "mixed valid utf-8 validates");
    check(u.utf8_validate(""), "empty validates");

    immutable char[3] bad = [cast(char) 0xFF, 'a', 'b'];
    check(!u.utf8_validate(bad[]), "an invalid byte fails validate");

    check(u.utf8_count("abc").unwrap() == 3, "count ascii");
    check(u.utf8_count("é€\U0001F600").unwrap() == 3,
          "count counts code points, not bytes");
    check(u.utf8_count("").unwrap() == 0, "count of empty");
    check(u.utf8_count(bad[]).is_err(), "count errors on bad input");
}

void test_iterator() {
    immutable string text = "aé€\U0001F600z";
    uint[8] got;
    int n = 0;
    auto it = u.utf8_runes(text);
    uint cp;
    while (u.utf8_next(it).take(cp)) got[n++] = cp;
    check(n == 5, "iterator yielded 5 code points");
    check(got[0] == 'a' && got[1] == 0x00E9 && got[2] == 0x20AC && got[3] == 0x1F600 && got[4] == 'z',
          "iterator yields the right code points in order");

    // lossy path: an invalid byte in the middle becomes U+FFFD
    immutable char[5] withBad = ['x', cast(char) 0xC3, cast(char) 0x28, 'y', 'z'];
    int m = 0, replacements = 0;
    auto it2 = u.utf8_runes(withBad[]);
    while (u.utf8_next(it2).take(cp)) {
        m++;
        if (cp == u.REPLACEMENT) replacements++;
    }
    check(replacements >= 1, "a bad byte yields U+FFFD and the loop continues");
    check(m >= 4, "the rest of the stream is still produced");
}

void test_sb_put() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));

    u.utf8_put(b, 'H');
    u.utf8_put(b, 0x00E9);       // é
    u.utf8_put(b, 0x20AC);       // €
    u.utf8_put(b, 0x1F600);      // 😀
    check(s.equals(s.sb_slice(b), "Hé€\U0001F600"), "utf8_put builds the bytes");
    check(u.utf8_count(s.sb_slice(b)).unwrap() == 4, "4 code points written");

    check(!u.utf8_put(b, 0xD800), "utf8_put of a surrogate is a no-op false");
    check(u.utf8_count(s.sb_slice(b)).unwrap() == 4, "nothing appended on the failed put");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_utf8_tests() {
    test_rune_len();
    test_decode_valid();
    test_decode_errors();
    test_encode_roundtrip();
    test_validate_and_count();
    test_iterator();
    test_sb_put();
}
