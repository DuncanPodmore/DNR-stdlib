module dnr.str_test;

import dnr.testing;
import dnr.mem;
import s = dnr.str;

// ---- 1. slice ops --------------------------------------------------------

void test_equals_prefix() {
    check(s.equals("abc", "abc"), "equals");
    check(!s.equals("abc", "abd"), "equals rejects a difference");
    check(!s.equals("abc", "ab"), "equals rejects a length mismatch");
    check(s.equals("", ""), "equals empty");
    check(s.equals_ci("HeLLo", "hello"), "equals_ci");
    check(!s.equals_ci("hello", "help"), "equals_ci rejects");

    check(s.starts_with("foobar", "foo"), "starts_with hit");
    check(!s.starts_with("foobar", "bar"), "starts_with miss");
    check(s.starts_with("foo", "foo"), "starts_with whole");
    check(!s.starts_with("fo", "foo"), "starts_with too short");
    check(s.ends_with("foobar", "bar"), "ends_with hit");
    check(!s.ends_with("foobar", "foo"), "ends_with miss");
}

void test_find() {
    check(s.index_of("hello", 'l') == 2, "index_of char");
    check(s.index_of("hello", 'z') == -1, "index_of char miss");
    check(s.last_index_of("hello", 'l') == 3, "last_index_of char");
    check(s.index_of("hello world", "world") == 6, "index_of sub");
    check(s.index_of("hello", "xyz") == -1, "index_of sub miss");
    check(s.index_of("hello", "") == 0, "index_of empty sub is 0");
    check(s.index_of("abc", "abcd") == -1, "index_of sub longer than s");
    check(s.contains("abcdef", "cde"), "contains sub");
    check(s.contains("abcdef", 'd'), "contains char");
    check(s.count_char("a,b,c,d", ',') == 3, "count_char");
}

void test_trim_strip() {
    check(s.equals(s.trim("  hi  "), "hi"), "trim both sides");
    check(s.equals(s.trim_left("\t\n x"), "x"), "trim_left");
    check(s.equals(s.trim_right("x \r\n"), "x"), "trim_right");
    check(s.equals(s.trim("   "), ""), "trim all-whitespace -> empty");
    check(s.equals(s.trim("nowhitespace"), "nowhitespace"), "trim no-op");

    check(s.equals(s.strip_prefix("key=value", "key="), "value"), "strip_prefix hit");
    check(s.equals(s.strip_prefix("value", "key="), "value"), "strip_prefix miss returns original");
    check(s.equals(s.strip_suffix("file.txt", ".txt"), "file"), "strip_suffix hit");
    check(s.equals(s.strip_suffix("file", ".txt"), "file"), "strip_suffix miss returns original");
}

void test_splitter() {
    const(char)[] f;

    auto it = s.split("a,b,c", ',');
    check(s.next(it, f) && s.equals(f, "a"), "split field 1");
    check(s.next(it, f) && s.equals(f, "b"), "split field 2");
    check(s.next(it, f) && s.equals(f, "c"), "split field 3");
    check(!s.next(it, f), "split exhausted");

    auto it2 = s.split("a,,c", ',');
    s.next(it2, f); check(s.equals(f, "a"), "split empty middle: a");
    s.next(it2, f); check(s.equals(f, ""),  "split empty middle: (empty)");
    s.next(it2, f); check(s.equals(f, "c"), "split empty middle: c");
    check(!s.next(it2, f), "split empty middle exhausted");

    auto it3 = s.split("a,", ',');
    s.next(it3, f); check(s.equals(f, "a"), "trailing sep: a");
    s.next(it3, f); check(s.equals(f, ""),  "trailing sep: empty final field");
    check(!s.next(it3, f), "trailing sep exhausted");

    auto it4 = s.split("", ',');
    check(s.next(it4, f) && s.equals(f, ""), "split of empty yields one empty field");
    check(!s.next(it4, f), "then exhausted");

    auto it5 = s.split_ws("  the  quick \t brown  ");
    int n = 0;
    while (s.next(it5, f)) {
        n++;
        check(f.length > 0, "split_ws never yields an empty token");
    }
    check(n == 3, "split_ws token count");
}

void test_classify() {
    check(s.is_space(' ') && s.is_space('\t') && s.is_space('\n'), "is_space");
    check(!s.is_space('x'), "is_space rejects");
    check(s.is_digit('7') && !s.is_digit('a'), "is_digit");
    check(s.is_hex_digit('f') && s.is_hex_digit('C') && !s.is_hex_digit('g'), "is_hex_digit");
    check(s.is_alpha('Q') && s.is_alpha('q') && !s.is_alpha('1'), "is_alpha");
    check(s.is_alnum('1') && s.is_alnum('z') && !s.is_alnum('-'), "is_alnum");
    check(s.to_lower('A') == 'a' && s.to_lower('z') == 'z', "to_lower");
    check(s.to_upper('a') == 'A' && s.to_upper('Z') == 'Z', "to_upper");
}

// ---- 2. parsing --------------------------------------------------------

void test_parse_int() {
    long v;
    check(s.parse_int("0", v) && v == 0, "parse_int 0");
    check(s.parse_int("42", v) && v == 42, "parse_int positive");
    check(s.parse_int("-42", v) && v == -42, "parse_int negative");
    check(s.parse_int("+7", v) && v == 7, "parse_int leading +");
    check(s.parse_int("9223372036854775807", v) && v == long.max, "parse_int long.max");
    check(s.parse_int("-9223372036854775808", v) && v == long.min, "parse_int long.min");

    check(!s.parse_int("", v), "parse_int empty");
    check(!s.parse_int("-", v), "parse_int lone sign");
    check(!s.parse_int("12x", v), "parse_int trailing junk");
    check(!s.parse_int(" 12", v), "parse_int leading space");
    check(!s.parse_int("9223372036854775808", v), "parse_int overflow long.max+1");
    check(!s.parse_int("99999999999999999999999", v), "parse_int huge overflow");

    ulong u;
    check(s.parse_uint("255", u) && u == 255, "parse_uint");
    check(!s.parse_uint("-1", u), "parse_uint rejects negative");
    check(s.parse_uint("18446744073709551615", u) && u == ulong.max, "parse_uint ulong.max");
    check(!s.parse_uint("18446744073709551616", u), "parse_uint overflow");
}

void test_parse_hex_float() {
    ulong u;
    check(s.parse_hex("ff", u) && u == 255, "parse_hex plain");
    check(s.parse_hex("0xFF", u) && u == 255, "parse_hex 0x prefix, upper");
    check(s.parse_hex("deadbeef", u) && u == 0xdeadbeef, "parse_hex 32-bit");
    check(s.parse_hex("ffffffffffffffff", u) && u == ulong.max, "parse_hex ulong.max");
    check(!s.parse_hex("0x1ffffffffffffffff", u), "parse_hex overflow");
    check(!s.parse_hex("xyz", u), "parse_hex junk");
    check(!s.parse_hex("0x", u), "parse_hex prefix only");

    double d;
    check(s.parse_float("3.14", d) && d > 3.13 && d < 3.15, "parse_float");
    check(s.parse_float("-0.5", d) && d == -0.5, "parse_float negative");
    check(s.parse_float("10", d) && d == 10.0, "parse_float integer literal");
    check(s.parse_float("1e3", d) && d == 1000.0, "parse_float exponent");
    check(!s.parse_float("3.14pie", d), "parse_float trailing junk");
    check(!s.parse_float("", d), "parse_float empty");
    check(!s.parse_float("  1.0", d), "parse_float leading space");
}

// ---- 3. Sb -----------------------------------------------------------

private Allocator tracked(ref Tracker t) { return tracking_allocator(t, malloc_allocator()); }

void test_sb_basic() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t), 4);

    s.sb_put(b, "hello");
    s.sb_put_char(b, ' ');
    s.sb_put(b, "world");
    check(s.equals(s.sb_slice(b), "hello world"), "sb_put builds the string");
    check(s.sb_len(b) == 11, "sb_len");
    check(b.ok, "sb still ok");

    s.sb_reset(b);
    check(s.sb_len(b) == 0, "sb_reset clears length");
    s.sb_put(b, "again");
    check(s.equals(s.sb_slice(b), "again"), "sb reuse after reset");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "sb_free released the buffer");
}

void test_sb_numbers() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));

    s.sb_put(b, "n=");
    s.sb_put_int(b, -1234);
    s.sb_put_char(b, ' ');
    s.sb_put_uint(b, 42);
    s.sb_put_char(b, ' ');
    s.sb_put_hex(b, 0xBEEF, 6);
    s.sb_put_char(b, ' ');
    s.sb_put_float(b, 3.14159, 2);
    check(s.equals(s.sb_slice(b), "n=-1234 42 00beef 3.14"), "sb number formatting");

    s.sb_reset(b);
    s.sb_put_int(b, 0);
    check(s.equals(s.sb_slice(b), "0"), "sb_put_int 0");

    s.sb_reset(b);
    s.sb_put_int(b, long.min);
    long back;
    check(s.parse_int(s.sb_slice(b), back) && back == long.min, "sb_put_int long.min round-trips");

    s.sb_reset(b);
    s.sb_put_rep(b, '=', 5);
    check(s.equals(s.sb_slice(b), "====="), "sb_put_rep");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void test_sb_cstr_and_grow() {
    Tracker t;
    s.Sb b = s.sb_make(tracked(t));
    foreach (i; 0 .. 200) s.sb_put(b, "ab");        // forces several grows
    check(s.sb_len(b) == 400, "sb grew to hold 400 chars");

    const(char)* c = s.sb_cstr(b);
    check(s.from_cstr(c).length == 400, "sb_cstr is null-terminated at the right place");
    check(s.sb_len(b) == 400, "sb_cstr did not count the terminator");

    s.sb_free(b);
    check(t.bytes_outstanding == 0, "freed clean");
}

void run_str_tests() {
    test_equals_prefix();
    test_find();
    test_trim_strip();
    test_splitter();
    test_classify();
    test_parse_int();
    test_parse_hex_float();
    test_sb_basic();
    test_sb_numbers();
    test_sb_cstr_and_grow();
}
